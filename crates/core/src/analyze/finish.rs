//! Turning the matched pairs and resolved references into the change report: non-code contracts, target
//! settings, external packages, review items, edges, components, and the analysis summary.

use super::checks::{similar_declarations, StructuralChecks};
use super::components::TargetSettings;
use super::regions::lcs;
use super::settings::setting_lines;
use super::{Builder, Mode, SettingSpot, SideData};
use crate::bazel;
use crate::config::Config;
use crate::lang::{self, Language};
use crate::model::*;
use crate::paths::{is_test_path, minimal_dirs};
use std::collections::{BTreeMap, BTreeSet, HashMap};

pub const ANALYZER_VERSION: &str = env!("CARGO_PKG_VERSION");

/// What the session knows beyond the two trees, for the report's `analysis` section.
#[derive(Clone, Debug, Default)]
pub struct AnalysisExtras {
    pub workspaces: Vec<WorkspaceInfo>,
    /// Why a language is not indexed, by language id.
    pub notes: BTreeMap<String, String>,
}

impl<'a> Builder<'a> {
    // MARK: Non-code contracts

    /// Changed non-code files that a language counts as part of a contract, as `file` review items.
    pub fn add_contract_files(&mut self) {
        let (base, head) = (&self.base.source, &self.head.source);
        let mut groups: BTreeMap<String, (String, &'static dyn Language)> = BTreeMap::new();
        let paths: BTreeSet<&String> = base.tree.keys().chain(head.tree.keys()).collect();
        for path in paths {
            if base.tree.get(path).map(|e| e.oid) == head.tree.get(path).map(|e| e.oid) {
                continue;
            }
            for l in &self.languages {
                if let Some((key, flag)) = l.contract_file(path) {
                    groups.insert(key, (flag, *l));
                    break;
                }
            }
        }
        for (key, (flag, language)) in groups {
            let exists_base = base.has_path(&key);
            let exists_head = head.has_path(&key);
            let change = if !exists_base {
                ChangeKind::Added
            } else if !exists_head {
                ChangeKind::Removed
            } else {
                ChangeKind::Body
            };
            let mut flags = vec![flag.clone()];
            if exists_base && exists_head {
                flags.extend(language.contract_file_flags(&key, &flag, base, head));
            }
            let flags: Vec<String> = flags.into_iter().map(|f| format!("{}:{f}", language.id())).collect();
            let s = if exists_head { Side::Head } else { Side::Base };
            let comp = self.nearest_component(&key, s);
            let lines = self.side(s).source.lines(&key).map(|l| l.len()).unwrap_or(1);
            self.file_review_items.push(ReviewItem {
                id: format!("{key}::{key}"),
                component: comp,
                kind: ItemKind::File,
                qualified_name: key.clone(),
                parent: None,
                is_interface: true,
                change,
                changes: vec![change],
                signature: Signature::default(),
                contract_flags: flags,
                tags: Vec::new(),
                location: Location { file: key.clone(), start_line: 1, end_line: lines.max(1) as u32, side: s },
                base_location: None,
                used_by: Vec::new(),
                depends_on: Vec::new(),
                similar: None,
                llm: None,
            });
        }
    }

    /// Changed build settings of a target that exists at both sides, as `target` review items: one for each
    /// file that sets a changed setting (a package's package.json and its tsconfig.json), located at the
    /// lines that set them, so that every region of the review item is in its file.
    pub fn add_target_settings(&mut self) {
        let (base, head) = (self.base, self.head);
        let (b, h) = (&base.layout.target_settings, &head.layout.target_settings);
        for (id, hs) in h {
            let Some(bs) = b.get(id) else { continue };
            let keys: BTreeSet<&String> = bs.settings.keys().chain(hs.settings.keys()).filter(|k| bs.settings.get(*k) != hs.settings.get(*k)).collect();
            let Some(language) = lang::named(&hs.language) else { continue };
            if keys.is_empty() {
                continue;
            }
            // The flag follows what changed: the setting's name and the values on both sides.
            let flag_of = |k: &String| -> String {
                let probe = format!("{k} {} {}", bs.settings.get(k).map(String::as_str).unwrap_or(""), hs.settings.get(k).map(String::as_str).unwrap_or(""));
                format!("{}:{}", language.id(), language.setting_flag(&changed_part(&probe, bs.settings.get(k), hs.settings.get(k), k)))
            };
            // Each setting belongs to the file that sets it at head, or that set it at base.
            let mut by_file: BTreeMap<&str, Vec<&String>> = BTreeMap::new();
            for k in &keys {
                let file = if hs.settings.contains_key(*k) { hs.file_of(k) } else { bs.file_of(k) };
                by_file.entry(file).or_default().push(k);
            }
            let name = head.layout.components.get(id).map(|c| c.name.clone()).unwrap_or_else(|| id.clone());
            let several = by_file.len() > 1;
            for (file, keys) in by_file {
                let flags: BTreeSet<String> = keys.iter().map(|k| flag_of(k)).collect();
                let show = |m: &BTreeMap<String, String>| -> Option<String> {
                    let lines: Vec<String> = keys.iter().filter_map(|k| m.get(*k).map(|v| if v == "on" { (*k).clone() } else { format!("{k} = {v}") })).collect();
                    (!lines.is_empty()).then(|| lines.join("\n"))
                };
                let placed = place_settings(base, head, file, &keys, bs, hs, &flag_of);
                let item_id = format!("{file}::{id} build settings");
                let qualified_name = if several { format!("{name} build settings ({})", crate::paths::file_name(file)) } else { format!("{name} build settings") };
                self.setting_spots.insert(item_id.clone(), placed.spots);
                self.file_review_items.push(ReviewItem {
                    id: item_id,
                    component: id.clone(),
                    kind: ItemKind::Target,
                    qualified_name,
                    parent: None,
                    is_interface: true,
                    change: ChangeKind::Modifiers,
                    changes: vec![ChangeKind::Modifiers],
                    signature: Signature { base: show(&bs.settings), head: show(&hs.settings) },
                    contract_flags: flags.into_iter().collect(),
                    tags: Vec::new(),
                    location: placed.location,
                    base_location: placed.base_location,
                    used_by: Vec::new(),
                    depends_on: Vec::new(),
                    similar: None,
                    llm: None,
                });
            }
        }
    }

    /// The component of the source file sharing the longest directory prefix with `path`.
    fn nearest_component(&self, path: &str, s: Side) -> String {
        let layout = &self.side(s).layout;
        let dirs: Vec<&str> = path.split('/').collect();
        let dirs = &dirs[..dirs.len() - 1];
        let mut best: Option<(usize, &String)> = None;
        for (f, c) in &layout.file_component {
            let fd: Vec<&str> = f.split('/').collect();
            let fd = &fd[..fd.len() - 1];
            let n = dirs.iter().zip(fd.iter()).take_while(|(a, b)| a == b).count();
            if n > 0 && best.map(|(bn, bc)| n > bn || (n == bn && c < bc)).unwrap_or(true) {
                best = Some((n, c));
            }
        }
        if let Some((_, c)) = best {
            return layout.components.get(c).and_then(|i| i.parent.clone()).unwrap_or_else(|| c.clone());
        }
        let top = if path.contains('/') { path.split('/').next().unwrap_or(".") } else { "." };
        format!("folder:{top}")
    }

    // MARK: External packages

    /// Lockfile pins of each language, and the modules each MODULE.bazel depends on, compared across the sides.
    pub fn diff_external_deps(&mut self) {
        let pins = |b: &Builder, s: Side| -> BTreeMap<String, String> {
            let source = &b.side(s).source;
            let mut result: BTreeMap<String, String> = BTreeMap::new();
            for l in &b.languages {
                for (k, v) in l.pinned_packages(source) {
                    result.entry(k).or_insert(v);
                }
            }
            for path in source.tree.keys().filter(|p| crate::paths::file_name(p) == "MODULE.bazel") {
                let Some(text) = source.text(path) else { continue };
                for (name, version) in bazel::module_deps(&text) {
                    result.entry(name).or_insert(if version.is_empty() { "override".to_string() } else { version });
                }
            }
            result
        };
        let b = pins(self, Side::Base);
        let h = pins(self, Side::Head);
        self.pinned_packages = b.keys().chain(h.keys()).cloned().collect();
        let names: BTreeSet<&String> = b.keys().chain(h.keys()).collect();
        for name in names {
            let change = match (b.get(name), h.get(name)) {
                (None, Some(to)) => ExternalDepChange { name: name.clone(), change: "added".into(), from: None, to: Some(to.clone()) },
                (Some(from), None) => ExternalDepChange { name: name.clone(), change: "removed".into(), from: Some(from.clone()), to: None },
                (Some(from), Some(to)) if from != to => ExternalDepChange { name: name.clone(), change: "bumped".into(), from: Some(from.clone()), to: Some(to.clone()) },
                _ => continue,
            };
            self.external_deps.push(change);
        }
    }

    // MARK: Output

    pub fn finish(mut self, repo: RepoInfo, config: &Config, extras: &AnalysisExtras) -> ChangeReport {
        // Review items: everything that changed (containers only when their own header changed or they carry flags).
        let mut review_items: Vec<ReviewItem> = Vec::new();
        for (i, p) in self.pairs.iter().enumerate() {
            let loc = p.any();
            let d = loc.decl();
            let mut changes = p.changes.clone();
            if d.is_container() {
                changes.retain(|c| *c != ChangeKind::Cosmetic);
                if changes.is_empty() && p.flags.is_empty() {
                    continue;
                }
                if changes.is_empty() {
                    changes = vec![ChangeKind::Body];
                }
            } else if changes.is_empty() {
                continue;
            }
            let s = p.side();
            let data = self.side(s);
            let comp = data.layout.components.get(&*loc.component);
            let mut tags: Vec<String> = Vec::new();
            if d.traits.contains("test") || comp.map(|c| c.is_test).unwrap_or(false) || is_test_path(&loc.file) {
                tags.push("test".into());
            }
            if data.source.generated.contains(&*loc.file) {
                tags.push("generated".into());
            }
            let parent_id = self.parent_pair(loc, s).map(|pp| self.pairs[pp].id.clone());
            // A use seen at both sides counts once, as a head use. Uses only at base keep side "base".
            let mut uses: BTreeMap<(String, String, String, u32), Usage> = BTreeMap::new();
            for u in self.used_by.get(&i).into_iter().flatten() {
                let mut u = u.clone();
                let key = (u.component.clone(), u.symbol.clone(), u.file.clone(), u.line);
                if u.side == Some(Side::Head) {
                    u.side = None;
                }
                if uses.get(&key).map(|have| have.side.is_none()).unwrap_or(false) {
                    continue;
                }
                uses.insert(key, u);
            }
            let mut used: Vec<Usage> = uses.into_values().collect();
            used.sort_by(|a, b| (&a.file, a.line, &a.symbol, &a.component).cmp(&(&b.file, b.line, &b.symbol, &b.component)));
            let mut deps: Vec<Usage> =
                self.depends_on.get(&i).into_iter().flatten().filter(|u| u.line >= d.start_line && u.line <= d.end_line).cloned().collect();
            deps.sort_by(|a, b| (&a.component, &a.symbol, a.line).cmp(&(&b.component, &b.symbol, b.line)));
            review_items.push(ReviewItem {
                id: p.id.clone(),
                component: loc.component.to_string(),
                kind: d.kind,
                qualified_name: d.qualified_name.clone(),
                parent: parent_id,
                is_interface: false,
                change: changes[0],
                changes,
                signature: Signature {
                    base: p.base.as_ref().map(|l| l.decl().signature_display.clone()),
                    head: p.head.as_ref().map(|l| l.decl().signature_display.clone()),
                },
                contract_flags: p.flags.clone(),
                tags,
                location: Location { file: loc.file.to_string(), start_line: d.start_line, end_line: d.end_line, side: s },
                base_location: p.head.as_ref().and(p.base.as_ref()).map(|b| Location {
                    file: b.file.to_string(),
                    start_line: b.decl().start_line,
                    end_line: b.decl().end_line,
                    side: Side::Base,
                }),
                used_by: used,
                depends_on: deps,
                similar: None,
                llm: None,
            });
        }
        // Interface: public/open/package, used from another component, or a requirement/case of an interface type.
        let mut interface_ids: BTreeSet<String> = BTreeSet::new();
        for (i, p) in self.pairs.iter().enumerate() {
            let access = p.head.as_ref().and_then(|h| h.decl().access.as_deref()).or_else(|| p.base.as_ref().and_then(|b| b.decl().access.as_deref()));
            let non_test_use = self.used_by.get(&i).into_iter().flatten().any(|u| {
                let is_test = self.head.layout.components.get(&u.component).or_else(|| self.base.layout.components.get(&u.component)).map(|c| c.is_test).unwrap_or(false);
                !is_test
            });
            if matches!(access, Some("public") | Some("open") | Some("package")) || non_test_use {
                interface_ids.insert(p.id.clone());
            }
        }
        for p in &self.pairs {
            let d = p.any().decl();
            if d.parent_kind != Some(ItemKind::Protocol) && d.kind != ItemKind::Case {
                continue;
            }
            if let Some(pp) = self.parent_pair(p.any(), p.side()) {
                if interface_ids.contains(&self.pairs[pp].id) {
                    interface_ids.insert(p.id.clone());
                }
            }
        }
        for item in review_items.iter_mut() {
            item.is_interface = interface_ids.contains(&item.id);
        }
        let similar = similar_declarations(&self, &review_items);
        for item in review_items.iter_mut() {
            item.similar = similar.get(&item.id).cloned();
        }
        review_items.extend(std::mem::take(&mut self.file_review_items));
        review_items.sort_by(|a, b| (&a.component, &a.location.file, a.location.start_line, &a.id).cmp(&(&b.component, &b.location.file, b.location.start_line, &b.id)));

        // Edges.
        let mut edges: Vec<Edge> = Vec::new();
        let mut keys: BTreeSet<(String, String)> = BTreeSet::new();
        for s in Side::BOTH {
            for (from, tos) in self.edge_refs(s) {
                for to in tos.keys() {
                    keys.insert((from.clone(), to.clone()));
                }
            }
        }
        let empty: Vec<Ref> = Vec::new();
        for (from, to) in keys {
            let b_refs = self.edge_refs(Side::Base).get(&from).and_then(|m| m.get(&to)).unwrap_or(&empty);
            let h_refs = self.edge_refs(Side::Head).get(&from).and_then(|m| m.get(&to)).unwrap_or(&empty);
            let b_syms: BTreeSet<&str> = b_refs.iter().map(|r| r.symbol.as_str()).collect();
            let h_syms: BTreeSet<&str> = h_refs.iter().map(|r| r.symbol.as_str()).collect();
            let status = if b_refs.is_empty() {
                EdgeStatus::Added
            } else if h_refs.is_empty() {
                EdgeStatus::Removed
            } else if b_syms != h_syms {
                EdgeStatus::Changed
            } else {
                EdgeStatus::Unchanged
            };
            let added: BTreeSet<&str> = h_syms.difference(&b_syms).copied().collect();
            let removed: BTreeSet<&str> = b_syms.difference(&h_syms).copied().collect();
            let sorted = |list: Vec<&Ref>| -> Vec<Ref> {
                let mut v: Vec<Ref> = list.into_iter().cloned().collect();
                v.sort_by(|a, b| (&a.file, a.line, &a.symbol).cmp(&(&b.file, b.line, &b.symbol)));
                v.dedup();
                v
            };
            let mut refs = sorted(h_refs.iter().filter(|r| added.contains(r.symbol.as_str())).collect());
            refs.extend(sorted(b_refs.iter().filter(|r| removed.contains(r.symbol.as_str())).collect()));
            let rest = if status == EdgeStatus::Removed { b_refs } else { h_refs };
            refs.extend(sorted(rest.iter().filter(|r| !added.contains(r.symbol.as_str()) && !removed.contains(r.symbol.as_str())).collect()));
            refs.truncate(self.options.max_refs_per_edge);
            edges.push(Edge {
                from,
                to,
                status,
                symbols_added: added.iter().map(|s| s.to_string()).collect(),
                symbols_removed: removed.iter().map(|s| s.to_string()).collect(),
                refs,
                ref_count: if status == EdgeStatus::Removed { b_refs.len() } else { h_refs.len() },
            });
        }

        // Components.
        let mut components: BTreeMap<String, Component> = BTreeMap::new();
        for s in Side::BOTH {
            let layout = &self.side(s).layout;
            let mut files_of: HashMap<&str, Vec<String>> = HashMap::new();
            for (f, c) in &layout.file_component {
                files_of.entry(c.as_str()).or_default().push(f.clone());
            }
            for (id, info) in &layout.components {
                let existed = components.contains_key(id);
                let c = components.entry(id.clone()).or_insert_with(|| Component {
                    id: id.clone(),
                    name: info.name.clone(),
                    kind: info.kind,
                    layer: info.layer.clone(),
                    module: info.module.clone(),
                    parent: info.parent.clone(),
                    is_test: info.is_test,
                    paths: Vec::new(),
                    status: Some(if s == Side::Base { "removed" } else { "added" }.to_string()),
                    changed_review_items: 0,
                    interface_changes: 0,
                    change_score: 0.0,
                    llm: None,
                });
                if s == Side::Head {
                    c.status = if existed { None } else { Some("added".to_string()) };
                    c.name = info.name.clone();
                    c.kind = info.kind;
                    c.layer = info.layer.clone();
                    c.module = info.module.clone();
                    c.parent = info.parent.clone();
                    c.is_test = info.is_test;
                }
                if s == Side::Head || c.paths.is_empty() {
                    c.paths = minimal_dirs(files_of.get(id.as_str()).map(Vec::as_slice).unwrap_or(&[]));
                }
            }
        }
        let external = |id: &str, name: &str| Component {
            id: id.to_string(),
            name: name.to_string(),
            kind: ComponentKind::External,
            layer: None,
            module: None,
            parent: None,
            is_test: false,
            paths: Vec::new(),
            status: None,
            changed_review_items: 0,
            interface_changes: 0,
            change_score: 0.0,
            llm: None,
        };
        for (id, name) in &self.external_components {
            components.entry(id.clone()).or_insert_with(|| external(id, name));
        }
        for e in &review_items {
            components.entry(e.component.clone()).or_insert_with(|| Component {
                kind: ComponentKind::Folder,
                ..external(&e.component, e.component.rsplit(':').next().unwrap_or(""))
            });
        }
        let mut raw: BTreeMap<String, f64> = BTreeMap::new();
        for e in review_items.iter().filter(|e| e.change != ChangeKind::Cosmetic) {
            let c = components.get_mut(&e.component).unwrap();
            c.changed_review_items += 1;
            let structural = matches!(e.change, ChangeKind::Signature | ChangeKind::Modifiers | ChangeKind::Added | ChangeKind::Removed) || !e.contract_flags.is_empty();
            if e.is_interface && structural {
                c.interface_changes += 1;
            }
            let mut w = if e.change == ChangeKind::Body { 1.0 } else { 1.5 };
            if e.is_interface && structural {
                w += 2.0;
            }
            w += e.contract_flags.len() as f64;
            if e.tags.iter().any(|t| t == "test" || t == "generated") {
                w *= 0.2;
            }
            *raw.entry(e.component.clone()).or_default() += w;
        }
        for e in edges.iter().filter(|e| e.status != EdgeStatus::Unchanged) {
            *raw.entry(e.from.clone()).or_default() += 1.0;
            *raw.entry(e.to.clone()).or_default() += 0.5;
        }
        let max_score = raw.values().cloned().fold(0.0f64, f64::max);
        for (id, v) in &raw {
            if let Some(c) = components.get_mut(id) {
                c.change_score = if max_score > 0.0 { (v / max_score * 1000.0).round() / 1000.0 } else { 0.0 };
            }
        }
        // Every package whose pin changed is a component, so the change's package list can point at it.
        for dep in &self.external_deps {
            let id = format!("ext:{}", dep.name);
            let c = components.entry(id.clone()).or_insert_with(|| external(&id, &dep.name));
            if dep.change == "added" {
                c.status = Some("added".to_string());
            }
            if dep.change == "removed" {
                c.status = Some("removed".to_string());
            }
        }
        // Components without source files (e.g. only Info.plist changed) take their paths from their review items.
        let mut item_files: BTreeMap<&str, Vec<String>> = BTreeMap::new();
        for e in review_items.iter().filter(|e| e.kind != ItemKind::Target) {
            item_files.entry(e.component.as_str()).or_default().push(e.location.file.clone());
        }
        for (id, c) in components.iter_mut() {
            if c.paths.is_empty() && c.kind != ComponentKind::External {
                c.paths = minimal_dirs(item_files.get(id.as_str()).map(Vec::as_slice).unwrap_or(&[]));
            }
        }

        let findings = StructuralChecks::new(&self, &review_items, &edges, config).run();
        let regions = self.build_regions(&review_items);

        // How each language was resolved, for the report and the UI's coverage line.
        let mut language_ids: Vec<String> = Vec::new();
        let mut coverage: Vec<LanguageCoverage> = Vec::new();
        for l in &self.languages {
            let present = self.head.files().values().chain(self.base.files().values()).any(|f| f.language == l.id());
            if !present {
                continue;
            }
            language_ids.push(l.id().to_string());
            let mut entry = self.coverage.get(l.id()).cloned().unwrap_or_else(|| {
                let files = self
                    .head
                    .files()
                    .iter()
                    .filter(|(p, f)| {
                        f.language == l.id()
                            && !self.head.source.generated.contains(*p)
                            && !is_test_path(p)
                            && !self.head.layout.file_component.get(*p).map(|c| self.head.is_test_component(c)).unwrap_or(false)
                    })
                    .count();
                let mode = self.mode_of(l.id());
                LanguageCoverage {
                    id: l.id().to_string(),
                    resolution: match mode {
                        Mode::Preliminary => "preliminary",
                        Mode::SyntaxOnly => "syntax",
                        Mode::NameBased => "name-based",
                        // An indexed language has its entry from `add_index`.
                        Mode::Index => "index",
                    }
                    .to_string(),
                    files,
                    indexed_files: 0,
                    note: None,
                    // CORE-003: a language that ended without an index gets none of the checks that need references.
                    held_back: if mode == Mode::SyntaxOnly {
                        ["unused-api", "orphaned", "untested", "conformers"].map(String::from).to_vec()
                    } else {
                        Vec::new()
                    },
                }
            });
            if entry.note.is_none() {
                entry.note = extras.notes.get(l.id()).cloned();
            }
            coverage.push(entry);
        }
        let resolution = if !self.indexed_languages.is_empty() {
            "index"
        } else if coverage.is_empty() || coverage.iter().any(|c| c.resolution == "preliminary") {
            "preliminary"
        } else if coverage.iter().all(|c| c.resolution == "name-based") {
            "name-based"
        } else {
            "syntax"
        };
        let gaps = self.coverage_gaps();
        for gap in gaps.iter().filter(|g| g.changed_files > 0) {
            self.warnings.insert(Warning::new(
                "coverage-gap",
                format!(
                    "{} changed {} file{} not analyzed: references into and out of {} are missing from this review (first: {}).",
                    gap.changed_files,
                    gap_name(&gap.language),
                    if gap.changed_files == 1 { " is" } else { "s are" },
                    if gap.changed_files == 1 { "it" } else { "them" },
                    gap.sample.join(", ")
                ),
            ));
        }
        let mut sorted_warnings: Vec<Warning> = self.warnings.iter().cloned().collect();
        sorted_warnings.sort_by(|a, b| {
            (&a.kind, a.file.as_deref().unwrap_or(""), a.line.unwrap_or(0), &a.message).cmp(&(&b.kind, b.file.as_deref().unwrap_or(""), b.line.unwrap_or(0), &b.message))
        });
        ChangeReport {
            version: REPORT_VERSION,
            analyzer: AnalyzerInfo { version: ANALYZER_VERSION.to_string(), resolution: resolution.to_string(), languages: language_ids },
            repo,
            analysis: AnalysisInfo {
                stage: self.options.stage.clone(),
                variant: self.options.variant.clone(),
                languages: coverage,
                gaps,
                workspaces: extras.workspaces.clone(),
            },
            components: components.into_values().collect(),
            edges,
            external_deps: self.external_deps.clone(),
            review_items,
            regions,
            warnings: sorted_warnings,
            findings,
            llm: None,
        }
    }

    /// Java and Objective-C files in the change: compiled into the reviewed targets, but not analyzed.
    fn coverage_gaps(&self) -> Vec<CoverageGap> {
        let (base, head) = (&self.base.source.tree, &self.head.source.tree);
        let mut gaps: BTreeMap<&'static str, CoverageGap> = BTreeMap::new();
        for path in head.keys() {
            if let Some(language) = lang::gap_language(path) {
                gaps.entry(language).or_insert_with(|| CoverageGap { language: language.to_string(), ..Default::default() }).files += 1;
            }
        }
        let paths: BTreeSet<&String> = base.keys().chain(head.keys()).collect();
        for path in paths {
            let Some(language) = lang::gap_language(path) else { continue };
            if base.get(path).map(|e| e.oid) == head.get(path).map(|e| e.oid) {
                continue;
            }
            let gap = gaps.entry(language).or_insert_with(|| CoverageGap { language: language.to_string(), ..Default::default() });
            gap.changed_files += 1;
            if gap.sample.len() < 5 {
                gap.sample.push(path.clone());
            }
        }
        gaps.into_values().collect()
    }
}

fn gap_name(language: &str) -> &str {
    match language {
        "java" => "Java",
        "objc" => "Objective-C",
        other => other,
    }
}

/// What to classify a changed setting by: for a list of compiler options, only the options that differ.
/// Where a build settings review item shows the settings one file sets.
struct PlacedSettings {
    spots: Vec<SettingSpot>,
    location: Location,
    base_location: Option<Location>,
}

/// The lines of `file` that set `keys`: at head for a setting head still has, at base for a removed one.
/// While the file exists at head, the review item is located there, and a removed setting is anchored after
/// the head line it followed; a setting whose line can't be found is shown at its rule (Bazel) or at the
/// top of its own file.
fn place_settings(
    base: &SideData,
    head: &SideData,
    file: &str,
    keys: &[&String],
    bs: &TargetSettings,
    hs: &TargetSettings,
    flag_of: &dyn Fn(&String) -> String,
) -> PlacedSettings {
    let lines_in = |side: &SideData, s: &TargetSettings, k: &String| -> Option<(String, (u32, u32))> {
        let f = s.file_of(k);
        let found = side.source.text(f).and_then(|t| setting_lines(&t, k, s.rule_line));
        let fallback = if f == s.file { s.rule_line.map(|l| (l, l)) } else { None };
        side.source.has_path(f).then(|| (f.to_string(), found.or(fallback).unwrap_or((1, 1))))
    };
    let head_lines = head.source.lines(file);
    // For anchoring removed settings: which head line each base line is matched with.
    let matches: Vec<(usize, usize)> = match (base.source.lines(file), &head_lines) {
        (Some(b), Some(h)) => {
            let norm = |l: &String| l.split_whitespace().collect::<Vec<_>>().join(" ");
            let (b, h): (Vec<String>, Vec<String>) = (b.iter().map(norm).collect(), h.iter().map(norm).collect());
            lcs(&b.iter().map(String::as_str).collect::<Vec<_>>(), &h.iter().map(String::as_str).collect::<Vec<_>>())
        }
        _ => Vec::new(),
    };
    let anchor_of = |base_line: u32| -> u32 {
        let next = matches.iter().find(|(b, _)| *b as u32 >= base_line).map(|(_, h)| *h as u32);
        next.unwrap_or_else(|| head_lines.as_ref().map(|l| l.len() as u32).unwrap_or(0))
    };
    let mut spots: BTreeMap<(Side, (u32, u32), Option<u32>), Vec<String>> = BTreeMap::new();
    let mut base_lines: Vec<u32> = Vec::new();
    let mut base_file: Option<String> = None;
    for k in keys {
        let at_base = if bs.settings.contains_key(*k) { lines_in(base, bs, k) } else { None };
        if let Some((f, l)) = &at_base {
            base_file.get_or_insert_with(|| f.clone());
            base_lines.extend([l.0, l.1]);
        }
        let spot = if hs.settings.contains_key(*k) {
            lines_in(head, hs, k).map(|(_, l)| (Side::Head, l, None))
        } else {
            at_base.map(|(_, l)| (Side::Base, l, head_lines.is_some().then(|| anchor_of(l.0))))
        };
        if let Some(spot) = spot {
            let flags = spots.entry(spot).or_default();
            let flag = flag_of(k);
            if !flags.contains(&flag) {
                flags.push(flag);
            }
        }
    }
    let mut spots: Vec<SettingSpot> = spots.into_iter().map(|((side, lines, anchor), flags)| SettingSpot { flags, side, lines, anchor }).collect();
    // In the order the reviewer reads them: by head position, a removed setting after the line it followed.
    spots.sort_by_key(|s| (s.anchor.unwrap_or(s.lines.0), s.side == Side::Base, s.lines));
    let span = |lines: &[u32]| (lines.iter().copied().min().unwrap_or(1).max(1), lines.iter().copied().max().unwrap_or(1).max(1));
    let removed = spots.iter().any(|s| s.side == Side::Base);
    if head_lines.is_some() {
        let lines: Vec<u32> = spots.iter().flat_map(|s| match s.anchor {
            Some(a) => vec![a],
            None => vec![s.lines.0, s.lines.1],
        }).collect();
        let (start, end) = span(&lines);
        let base_location = (removed && !base_lines.is_empty()).then(|| {
            let (start, end) = span(&base_lines);
            Location { file: base_file.clone().unwrap_or_else(|| file.to_string()), start_line: start, end_line: end, side: Side::Base }
        });
        PlacedSettings { spots, location: Location { file: file.to_string(), start_line: start, end_line: end, side: Side::Head }, base_location }
    } else {
        // The file is gone at head: its settings are shown where base set them.
        let (start, end) = span(&base_lines);
        PlacedSettings { spots, location: Location { file: base_file.unwrap_or_else(|| file.to_string()), start_line: start, end_line: end, side: Side::Base }, base_location: None }
    }
}

fn changed_part(probe: &str, base: Option<&String>, head: Option<&String>, key: &str) -> String {
    let (Some(b), Some(h)) = (base, head) else { return probe.to_string() };
    let bs: BTreeSet<&str> = b.split_whitespace().collect();
    let hs: BTreeSet<&str> = h.split_whitespace().collect();
    let diff: Vec<&str> = bs.symmetric_difference(&hs).copied().collect();
    if diff.is_empty() {
        probe.to_string()
    } else {
        format!("{key} {}", diff.join(" "))
    }
}
