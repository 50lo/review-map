//! Resolving references into edges, `usedBy`, and `dependsOn`, per language and mode.
//!
//! - Index: every reference in a covered file resolves to the exact declaration the index names.
//! - Preliminary and syntax-only: only imports that identify one module or one declaration, and the
//!   dependencies BUILD files declare, become links. This is also what files an index misses get.
//! - Name-based: names are looked up as the prototype did, with its visibility rules. Only the
//!   comparison report the user asks for does this; the main report never matches by name (CORE-003).

use super::{Builder, CheckCoverage, DeclKey, Mode, SideData};
use crate::index::{IndexedRef, SideIndex};
use crate::lang::Language;
use crate::model::*;
use crate::parse::{NameRef, ParsedFile};
use crate::paths::is_test_path;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

struct MemberEntry {
    component: String,
    root_type: String,
    pair: usize,
    package: Option<String>,
}

impl<'a> Builder<'a> {
    /// Adds a language's exact references. A file is resolved through the index only when the index covers
    /// it at every side it exists at, so that different coverage of base and head can't show up as added or
    /// removed dependencies. The other files show only links that syntax proves, as a language without an
    /// index does, and are listed in an `index-partial` warning (CORE-003); test and generated files are left
    /// out of that list, because the review scope often doesn't build test targets.
    ///
    /// The checks that claim "no callers" or "no test references" need more: every file at head that could
    /// hold such a reference, generated ones included. Where the index misses one, they are held back
    /// (`check_coverage`) and a `checks-held-back` warning gives the counts.
    pub fn add_index(&mut self, lang: &'static dyn Language, base: &SideIndex, head: &SideIndex) {
        self.indexed_languages.insert(lang.id().to_string());
        let given = [base, head];
        // (covered, all) at head: non-test files, generated ones included, and test files.
        let mut callers = (0usize, 0usize);
        let mut tests = (0usize, 0usize);
        for (i, s) in Side::BOTH.into_iter().enumerate() {
            for w in &given[i].warnings {
                self.warnings.insert(w.clone());
            }
            let data = self.side(s);
            let other = self.side(s.other());
            let mut all = 0usize;
            let mut missing: Vec<String> = Vec::new();
            let mut usable: Vec<(String, Vec<IndexedRef>)> = Vec::new();
            for (path, file) in data.files() {
                if file.language != lang.id() {
                    continue;
                }
                let covered = given[i].refs.contains_key(path) && (!other.files().contains_key(path) || given[1 - i].refs.contains_key(path));
                if covered {
                    usable.push((path.clone(), given[i].refs[path].clone()));
                }
                let Some(c) = data.layout.file_component.get(path) else { continue };
                let is_test = data.is_test_component(c) || is_test_path(path);
                if s == Side::Head {
                    let count = if is_test { &mut tests } else { &mut callers };
                    count.1 += 1;
                    count.0 += covered as usize;
                }
                if data.source.generated.contains(path) || is_test {
                    continue;
                }
                all += 1;
                if !covered {
                    missing.push(path.clone());
                }
            }
            if !missing.is_empty() {
                let first: Vec<&str> = missing.iter().take(3).map(String::as_str).collect();
                self.warnings.insert(Warning::new(
                    "index-partial",
                    format!(
                        "{} of {all} {} files are not covered by the index at {} (or only at one side), so only links that syntax proves are shown for them (first: {}).",
                        missing.len(),
                        lang.display_name(),
                        s.name(),
                        first.join(", ")
                    ),
                ));
            }
            if s == Side::Head {
                self.coverage.insert(
                    lang.id().to_string(),
                    LanguageCoverage {
                        id: lang.id().to_string(),
                        resolution: "index".to_string(),
                        files: all,
                        indexed_files: all - missing.len(),
                        ..Default::default()
                    },
                );
            }
            let target = self.index_mut(s);
            for (path, refs) in usable {
                target.insert(path, refs);
            }
        }

        let checks = CheckCoverage { callers: callers.0 == callers.1, tests: tests.0 == tests.1 };
        let name = lang.display_name();
        let mut held_back: Vec<String> = Vec::new();
        let mut reasons: Vec<String> = Vec::new();
        if !checks.callers {
            held_back.extend(["unused-api".to_string(), "orphaned".to_string()]);
            reasons.push(format!(
                "unused-api and orphaned, because the index misses {} of {} non-test {name} files at head, so a caller there can't be ruled out",
                callers.1 - callers.0,
                callers.1
            ));
        }
        if !checks.tests {
            held_back.push("untested".to_string());
            reasons.push(format!(
                "untested, because the index misses {} of {} {name} test files at head (the review scope may not build the test targets)",
                tests.1 - tests.0,
                tests.1
            ));
        }
        if !reasons.is_empty() {
            self.warnings.insert(Warning::new("checks-held-back", format!("{name} checks that did not run: {}.", reasons.join("; "))));
        }
        if let Some(c) = self.coverage.get_mut(lang.id()) {
            c.held_back = held_back;
        }
        self.check_coverage.insert(lang.id().to_string(), checks);
    }

    /// The id and name of an external package's component. Bazel writes a Swift package's "-" as "_" in its
    /// repository name ("swiftpkg_indexstore_db"), while the lockfile and the map know the package by its
    /// pinned identity ("indexstore-db"). The pinned identity wins when there is one, so a dependency a BUILD
    /// file declares and an import of the same package meet in one component.
    fn external_id(&self, name: &str) -> (String, String) {
        let name = self.pinned_packages.iter().find(|p| same_package(p, name)).map(String::as_str).unwrap_or(name);
        (format!("ext:{name}"), name.to_string())
    }

    fn external_component(&mut self, module: &str, lang: &dyn Language, data: &SideData) -> Option<String> {
        let name = match data.layout.externals.values().find(|name| same_package(name, module)) {
            Some(name) => name.clone(),
            None => lang.package_of_module(module, &self.pinned_packages)?,
        };
        let (id, name) = self.external_id(&name);
        self.external_components.insert(id.clone(), name);
        Some(id)
    }

    /// Index mode for one file: each reference resolves to the exact declaration it points at.
    fn resolve_indexed(&mut self, s: Side, path: &str, file: &ParsedFile, comp: &str, refs: &[IndexedRef]) {
        let data = self.side(s);
        let lang = self.language_of(path);
        let mut seen: HashSet<(u32, &str, usize)> = HashSet::new();
        for r in refs {
            let Some(target_comp) = data.layout.file_component.get(&r.target_file) else { continue };
            let Some((target_index, target)) = self.decl_at(s, &r.target_file, r.target_line, &r.name) else { continue };
            let encl_index = file.enclosing_index(r.line);
            let encl = encl_index.map(|i| &file.decls[i]);
            // References to parts of the enclosing declaration itself (its parameters, local names) are not uses.
            if r.target_file == path {
                if let Some(e) = encl {
                    if target.start_line >= e.start_line && target.end_line <= e.end_line {
                        continue;
                    }
                }
            }
            if !seen.insert((r.line, r.target_file.as_str(), target_index)) {
                continue;
            }
            let usage = Usage {
                component: comp.to_string(),
                symbol: encl.map(|e| e.qualified_name.clone()).unwrap_or_else(|| "(top level)".to_string()),
                file: path.to_string(),
                line: r.line,
                isolation: lang.isolation(file, r.line),
                side: Some(s),
            };
            let target_pair = self.pair_of.get(&DeclKey::new(s, &r.target_file, target_index)).copied();
            if let (Side::Head, Some(tp)) = (s, target_pair) {
                self.index_callers.entry(tp).or_default().push(usage.clone());
            }
            if target_comp == comp {
                continue;
            }
            let symbol = self.top_level_decl(s, &r.target_file, target_index).map(|d| d.name.clone()).unwrap_or_else(|| target.name.clone());
            self.add_ref(s, comp, target_comp, Ref { file: path.to_string(), line: r.line, symbol, side: s });
            if let Some(tp) = target_pair {
                self.used_by.entry(tp).or_default().insert(usage);
            }
            if let Some(ei) = encl_index {
                if let Some(&pi) = self.pair_of.get(&DeclKey::new(s, path, ei)) {
                    self.depends_on.entry(pi).or_default().insert(Usage {
                        component: target_comp.clone(),
                        symbol: target.qualified_name.clone(),
                        file: path.to_string(),
                        line: r.line,
                        isolation: None,
                        side: None,
                    });
                }
            }
        }
    }

    pub fn resolve_references(&mut self) {
        for s in Side::BOTH {
            let data = self.side(s);
            let layout = &data.layout;
            // Changed member review items by name, for member-level usage.
            let mut members_by_name: HashMap<String, Vec<MemberEntry>> = HashMap::new();
            // Top-level declarations by (component, name) -> pair index, for type-level usage.
            let mut top_level: HashMap<String, usize> = HashMap::new();
            let mut package_top_level: HashMap<String, usize> = HashMap::new();
            for (i, p) in self.pairs.iter().enumerate() {
                let Some(loc) = p.at(s) else { continue };
                let d = loc.decl();
                if let (Some(scope), false, true) = (&d.scope, d.is_container(), p.is_changed()) {
                    let root = scope.split('.').next().unwrap_or(scope).to_string();
                    members_by_name.entry(d.name.clone()).or_default().push(MemberEntry {
                        component: loc.component.to_string(),
                        root_type: root,
                        pair: i,
                        package: loc.parsed.package_name.clone(),
                    });
                }
                if d.is_top_level() {
                    if d.kind != ItemKind::Extension {
                        top_level.insert(format!("{}|{}", loc.component, d.name), i);
                    }
                    if let Some(package) = &loc.parsed.package_name {
                        package_top_level.insert(format!("{package}|{}|{}", loc.component, d.name), i);
                    }
                }
            }

            // Source packages can span build targets, and a target can contain many packages. Index by
            // package AND declared name so unrelated packages never become visible together.
            let mut package_declarations: HashMap<&str, HashMap<&str, BTreeSet<&str>>> = HashMap::new();
            let mut package_components: HashMap<&str, BTreeSet<&str>> = HashMap::new();
            for (path, file) in data.files() {
                let (Some(package), Some(component)) = (file.package_name.as_deref(), layout.file_component.get(path)) else { continue };
                package_components.entry(package).or_default().insert(component);
                for decl in file.decls.iter().filter(|d| d.is_top_level()) {
                    package_declarations.entry(package).or_default().entry(decl.name.as_str()).or_default().insert(component);
                }
            }
            let package_binding = |qualified: &str| -> Option<(String, String)> {
                let package = package_components
                    .keys()
                    .filter(|p| !p.is_empty() && qualified.len() > p.len() && qualified.starts_with(**p) && qualified.as_bytes()[p.len()] == b'.')
                    .max_by_key(|p| p.len())?;
                let name = qualified[package.len() + 1..].split('.').next().unwrap_or("").to_string();
                Some((package.to_string(), name))
            };

            let mut ambiguous: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
            let paths: Vec<&String> = data.files().keys().collect();
            for path in paths {
                let file = &data.files()[path];
                let Some(comp) = layout.file_component.get(path) else { continue };
                let lang = self.language_of(path);
                let mode = self.mode_of(lang.id());
                let module = layout.components.get(comp).and_then(|c| c.module.clone());
                let mut visible: HashSet<&str> = file.imports.iter().map(|i| i.name.as_str()).collect();
                if let Some(m) = &module {
                    visible.insert(m.as_str());
                }

                for imp in &file.imports {
                    let import_ref = |side: Side| Ref { file: path.clone(), line: imp.line, symbol: format!("import {}", imp.name), side };
                    if file.package_name.is_some() {
                        // Kotlin: an import names a package or one declaration of a package.
                        let targets: BTreeSet<String> = if file.wildcard_imports.contains(&imp.name) {
                            package_components.get(imp.name.as_str()).map(|s| s.iter().map(|c| c.to_string()).collect()).unwrap_or_default()
                        } else if let Some((package, name)) = package_binding(&imp.name) {
                            package_declarations
                                .get(package.as_str())
                                .and_then(|m| m.get(name.as_str()))
                                .map(|s| s.iter().map(|c| c.to_string()).collect())
                                .unwrap_or_default()
                        } else {
                            BTreeSet::new()
                        };
                        // A name that several components declare is only an edge to each of them when matching
                        // by name, in the comparison report. Everywhere else it needs one owner (CORE-003).
                        if targets.len() == 1 || mode == Mode::NameBased {
                            for target in targets.iter().filter(|t| *t != comp) {
                                self.add_ref(s, comp, target, import_ref(s));
                            }
                        }
                        continue;
                    }
                    // Swift: an import names a module, and the build graph says which component compiles into it.
                    if let Some(target) = layout.module_component.get(&imp.name) {
                        if layout.components.get(target).and_then(|c| c.module.as_ref()) != module.as_ref() {
                            let target = target.clone();
                            self.add_ref(s, comp, &target, import_ref(s));
                        }
                    } else if let Some(ext) = self.external_component(&imp.name, lang, data) {
                        self.add_ref(s, comp, &ext, import_ref(s));
                    } else if !lang.is_platform_module(&imp.name) && mode != Mode::Preliminary && !layout.module_component.is_empty() {
                        self.warnings.insert(Warning::new("unresolved-import", format!("import {} matches no target or known package product.", imp.name)));
                    }
                }

                if let Some(refs) = self.index_refs(s, path).cloned() {
                    self.resolve_indexed(s, path, file, comp, &refs);
                    continue;
                }
                // CORE-003: a file without index data keeps the links above, which syntax proves, and no more.
                if mode != Mode::NameBased {
                    continue;
                }

                // Name matching, for the comparison report only.
                let mut resolved_types: HashSet<String> = HashSet::new();
                let mut seen_ref: HashSet<&NameRef> = HashSet::new();
                for r in &file.type_refs {
                    if !seen_ref.insert(r) {
                        continue;
                    }
                    let target: String;
                    let mut resolved_name = r.name.clone();
                    let mut resolved_package: Option<String> = None;
                    if let Some(own_package) = file.package_name.as_deref() {
                        let mut choices: Vec<(String, String, String)> = Vec::new();
                        let add_choices = |choices: &mut Vec<(String, String, String)>, package: &str, name: &str| {
                            if let Some(components) = package_declarations.get(package).and_then(|m| m.get(name)) {
                                for component in components {
                                    choices.push((package.to_string(), component.to_string(), name.to_string()));
                                }
                            }
                        };
                        if let Some(m) = &r.module {
                            let qualified = if m.is_empty() { r.name.clone() } else { format!("{m}.{}", r.name) };
                            if let Some((package, name)) = package_binding(&qualified) {
                                add_choices(&mut choices, &package, &name);
                            }
                        } else {
                            add_choices(&mut choices, own_package, &r.name);
                            if choices.is_empty() {
                                let stars: BTreeSet<&String> = file.wildcard_imports.iter().collect();
                                for package in stars {
                                    add_choices(&mut choices, package, &r.name);
                                }
                            }
                        }
                        if choices.iter().any(|c| c.1 == *comp) {
                            continue;
                        }
                        if choices.len() > 1 {
                            ambiguous.entry(r.name.clone()).or_default().extend(choices.iter().map(|c| c.1.clone()));
                            continue;
                        }
                        let Some(choice) = choices.into_iter().next() else { continue };
                        target = choice.1;
                        resolved_name = choice.2;
                        resolved_package = Some(choice.0);
                    } else {
                        let Some(cands) = data.decl_table.get(&r.name) else { continue };
                        if cands.contains(comp) {
                            continue;
                        }
                        let mut cands: Vec<&String> = cands
                            .iter()
                            .filter(|c| match layout.components.get(*c).and_then(|i| i.module.as_deref()) {
                                Some(m) => visible.contains(m),
                                None => true,
                            })
                            .collect();
                        // A name imported from a module is that module's, or no component's (a third-party package).
                        // An unqualified name is the file's own module's first.
                        if let Some(m) = &r.module {
                            cands.retain(|c| layout.components.get(*c).and_then(|i| i.module.as_ref()) == Some(m));
                        } else if let Some(m) = &module {
                            let own: Vec<&String> = cands.iter().copied().filter(|c| layout.components.get(*c).and_then(|i| i.module.as_ref()) == Some(m)).collect();
                            if !own.is_empty() {
                                cands = own;
                            }
                        }
                        if cands.len() > 1 {
                            ambiguous.entry(r.name.clone()).or_default().extend(cands.into_iter().cloned());
                            continue;
                        }
                        let Some(only) = cands.first() else { continue };
                        target = (*only).clone();
                    }
                    self.add_ref(s, comp, &target, Ref { file: path.clone(), line: r.line, symbol: r.name.clone(), side: s });
                    resolved_types.insert(format!("{}{target}|{resolved_name}", resolved_package.as_ref().map(|p| format!("{p}|")).unwrap_or_default()));
                    let encl_index = file.enclosing_index(r.line);
                    let encl = encl_index.map(|i| &file.decls[i]);
                    let referenced = resolved_package
                        .as_ref()
                        .and_then(|p| package_top_level.get(&format!("{p}|{target}|{resolved_name}")))
                        .or_else(|| top_level.get(&format!("{target}|{resolved_name}")))
                        .copied();
                    if let Some(ti) = referenced {
                        self.used_by.entry(ti).or_default().insert(Usage {
                            component: comp.clone(),
                            symbol: encl.map(|e| e.qualified_name.clone()).unwrap_or_else(|| "(top level)".to_string()),
                            file: path.clone(),
                            line: r.line,
                            isolation: lang.isolation(file, r.line),
                            side: Some(s),
                        });
                    }
                    if let Some(ei) = encl_index {
                        if let Some(&pi) = self.pair_of.get(&DeclKey::new(s, path, ei)) {
                            self.depends_on.entry(pi).or_default().insert(Usage {
                                component: target.clone(),
                                symbol: r.name.clone(),
                                file: path.clone(),
                                line: r.line,
                                isolation: None,
                                side: None,
                            });
                        }
                    }
                }
                let member_refs: BTreeSet<&NameRef> = file.member_refs.iter().collect();
                for r in member_refs {
                    let Some(entries) = members_by_name.get(&r.name) else { continue };
                    for m in entries {
                        let key = format!("{}{}|{}", m.package.as_ref().map(|p| format!("{p}|")).unwrap_or_default(), m.component, m.root_type);
                        if m.component == *comp || !resolved_types.contains(&key) {
                            continue;
                        }
                        let encl = file.enclosing_decl(r.line);
                        self.used_by.entry(m.pair).or_default().insert(Usage {
                            component: comp.clone(),
                            symbol: encl.map(|e| e.qualified_name.clone()).unwrap_or_else(|| "(top level)".to_string()),
                            file: path.clone(),
                            line: r.line,
                            isolation: lang.isolation(file, r.line),
                            side: Some(s),
                        });
                    }
                }
            }
            for (name, comps) in ambiguous {
                let list: Vec<String> = comps.into_iter().collect();
                self.warnings.insert(Warning::new(
                    "ambiguous-name",
                    format!("{name} is declared in {}; references to it were not resolved ({}).", list.join(", "), s.name()),
                ));
            }
            // Dependencies that BUILD files declare.
            for dep in &layout.declared_deps {
                let to = match layout.externals.get(&dep.to) {
                    Some(name) => {
                        let (id, name) = self.external_id(name);
                        self.external_components.insert(id.clone(), name);
                        id
                    }
                    None => dep.to.clone(),
                };
                self.add_ref(s, &dep.from, &to, Ref { file: dep.file.clone(), line: 0, symbol: dep.symbol.clone(), side: s });
            }
        }
    }
}

/// Whether two names are one package, written with "-" or "_" and in any case.
fn same_package(a: &str, b: &str) -> bool {
    let flat = |s: &str| s.replace(['-', '_'], "").to_lowercase();
    flat(a) == flat(b)
}
