//! TypeScript: tree-sitter for parsing and risk marks (`parse::typescript`), npm packages and `tsconfig`
//! projects for components, lockfiles for pins, import resolution through the revision's own projects
//! (`project`), and contract flags (`flags`). Indexing is in `index::typescript`. A port of the prototype's
//! `TypeScriptLanguage.swift` and `TypeScriptComponents.swift`.

pub mod flags;
pub mod project;

use super::{risk, Language};
use crate::analyze::components::{ComponentInfo, ComponentLayout, DeclaredDep, TargetSettings};
use crate::analyze::{Builder, SideSource};
use crate::model::{ComponentKind, ItemKind};
use crate::parse::Declaration;
use crate::paths::{file_name, is_test_path, is_under, strip_dir};
use project::{is_node_builtin, typed_module, Project, Resolved};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;

pub struct TypeScriptLanguage;

pub const EXTENSIONS: &[&str] = project::SOURCE_EXTENSIONS;
/// Dependency fields that make a dependency of the package itself; devDependencies are only known names.
const DEPENDENCY_FIELDS: &[&str] = &["dependencies", "peerDependencies", "optionalDependencies"];
const ALL_DEPENDENCY_FIELDS: &[&str] = &["dependencies", "peerDependencies", "optionalDependencies", "devDependencies"];

/// The revision's TypeScript projects, read once per side.
pub fn project(source: &SideSource) -> Arc<Project> {
    source.memo("typescript-project", || Project::build(source.tree.keys(), &|p: &str| source.bytes(p)))
}

/// The module a dependency name stands for in imports: a type-only package stands for the module it types.
fn import_name(dependency: &str) -> String {
    typed_module(dependency).unwrap_or_else(|| dependency.to_string())
}

fn stringify(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

struct Unit<'p> {
    id: String,
    dir: String,
    name: String,
    kind: ComponentKind,
    module: Option<String>,
    manifest: String,
    package: Option<&'p project::Package>,
}

impl Language for TypeScriptLanguage {
    fn id(&self) -> &'static str {
        "typescript"
    }

    fn display_name(&self) -> &'static str {
        "TypeScript"
    }

    fn is_source(&self, path: &str) -> bool {
        let name = file_name(path);
        EXTENSIONS.iter().any(|e| name.len() > e.len() + 1 && name.ends_with(&format!(".{e}")))
    }

    fn generated_patterns(&self) -> &'static [&'static str] {
        &["**/*.generated.ts", "**/*.generated.tsx", "**/__generated__/**", "**/*.gen.ts", "**/*_pb.ts", "**/*.pb.ts"]
    }

    fn is_platform_module(&self, module: &str) -> bool {
        is_node_builtin(module)
    }

    /// Versions of the packages a package.json lists, from yarn.lock, pnpm-lock.yaml (Bazel's rules_js reads
    /// it), package-lock.json, or bun.lock. Transitive packages are left out: a regenerated lockfile would
    /// otherwise list hundreds of bumps.
    fn pinned_packages(&self, side: &SideSource) -> BTreeMap<String, String> {
        let project = project(side);
        let mut direct: BTreeSet<String> = BTreeSet::new();
        for p in &project.packages {
            direct.extend(p.dependencies(ALL_DEPENDENCY_FIELDS));
        }
        let lockfiles: Vec<&String> = side.tree.keys().filter(|p| project::LOCKFILES.contains(&file_name(p)) && !p.split('/').any(|s| s == "node_modules")).collect();
        let mut texts: Vec<(String, String)> = Vec::new();
        for path in lockfiles {
            if let Some(text) = side.text(path) {
                texts.push((file_name(path).to_string(), text));
            }
        }
        pins(&direct, &texts)
    }

    /// npm package names are their own identities; a type-only package's module is the package it types.
    fn package_of_module(&self, module: &str, pinned: &BTreeSet<String>) -> Option<String> {
        if pinned.contains(module) || pinned.contains(&format!("@types/{}", module.trim_start_matches('@').replace('/', "__"))) {
            Some(module.to_string())
        } else {
            None
        }
    }

    fn contract_flags(&self, builder: &Builder, pairs: &[usize]) -> HashMap<usize, Vec<String>> {
        flags::flags(builder, pairs)
    }

    fn contract_file(&self, _path: &str) -> Option<(String, String)> {
        None
    }

    fn contract_file_flags(&self, _key: &str, _flag: &str, _base: &SideSource, _head: &SideSource) -> Vec<String> {
        Vec::new()
    }

    /// Settings are keyed "package.json <field>" and "tsconfig <compiler option>".
    fn setting_flag(&self, key: &str) -> String {
        let Some((kind, name)) = key.split_once(' ') else { return "settings-changed".to_string() };
        if kind == "package.json" {
            return if name == "engines" { "engines-changed" } else { "package-exports-changed" }.to_string();
        }
        let lower = name.to_lowercase();
        let flag = if lower.starts_with("strict") || lower.starts_with("noimplicit") || lower.starts_with("nounchecked") || lower == "exactoptionalpropertytypes" {
            "strictness-changed"
        } else if matches!(lower.as_str(), "target" | "lib" | "jsx") {
            "target-changed"
        } else if matches!(
            lower.as_str(),
            "module"
                | "moduleresolution"
                | "paths"
                | "baseurl"
                | "rootdir"
                | "rootdirs"
                | "esmoduleinterop"
                | "verbatimmodulesyntax"
                | "isolatedmodules"
                | "allowsyntheticdefaultimports"
                | "resolvejsonmodule"
                | "moduledetection"
                | "types"
                | "typeroots"
        ) {
            "module-resolution-changed"
        } else {
            "compiler-options-changed"
        };
        flag.to_string()
    }

    /// Compiler settings are medium; a package's entry points and every declaration-level flag are high on an
    /// interface and medium elsewhere.
    fn flag_risk(&self, flag: &str, is_interface: bool) -> f64 {
        if matches!(flag, "strictness-changed" | "target-changed" | "module-resolution-changed" | "compiler-options-changed" | "engines-changed" | "settings-changed") {
            return risk::MEDIUM;
        }
        if flag == "package-exports-changed" || is_interface {
            risk::HIGH
        } else {
            risk::MEDIUM
        }
    }

    /// React components: declarations that return JSX, members of class components, and declarations typed
    /// as components or elements.
    fn is_view_code(&self, d: &Declaration, inherits: &HashSet<String>) -> bool {
        if d.traits.contains("jsx") || inherits.contains("Component") || inherits.contains("PureComponent") {
            return true;
        }
        let types = format!("{} {}", d.signature_display, d.type_annotation.as_deref().unwrap_or(""));
        ["JSX.Element", "ReactNode", "ReactElement", "FC<", "FunctionComponent", "ComponentType"].iter().any(|t| types.contains(t))
    }

    /// Named exports and their public members; default exports are left out.
    fn is_public_api(&self, decl: &Declaration, enclosing: &[&Declaration]) -> bool {
        if decl.modifiers.iter().any(|m| m == "default") {
            return false;
        }
        if decl.is_top_level() {
            return decl.modifiers.iter().any(|m| m == "export");
        }
        if decl.access.as_deref().map(|a| a != "public").unwrap_or(false) {
            return false;
        }
        let Some(top) = enclosing.iter().find(|d| d.is_top_level()) else { return false };
        top.modifiers.iter().any(|m| m == "export") && !top.modifiers.iter().any(|m| m == "default")
    }

    /// Constructors, default exports, and names that aren't plain identifiers (`#private`, computed keys).
    fn is_implicitly_called(&self, decl: &Declaration) -> bool {
        decl.name == "constructor" || decl.name == "default" || decl.kind == ItemKind::Init || !decl.name.chars().next().map(|c| c.is_alphabetic() || c == '_' || c == '$').unwrap_or(false)
    }

    /// Packages, then `tsconfig.json` directories that no package covers, for the TypeScript files that no
    /// Bazel target claimed. A component's test files go to a test component of their own.
    fn add_components(&self, source: &SideSource, layout: &mut ComponentLayout) {
        let project = project(source);
        let files: Vec<&String> = source.files.iter().filter(|(p, f)| f.language == "typescript" && !layout.file_component.contains_key(*p)).map(|(p, _)| p).collect();
        // Directories whose files a Bazel target owns: the package is that target, not an npm component.
        let bazel_owned: Vec<&String> = layout.file_component.keys().collect();
        let owned_by_bazel = |dir: &str| bazel_owned.iter().any(|f| is_under(f, dir));
        let mut units: Vec<Unit> = Vec::new();
        for p in &project.packages {
            if p.dir.is_empty() && p.is_workspace_root() {
                continue;
            }
            if p.name.as_ref().map(|n| layout.module_component.contains_key(n)).unwrap_or(false) || owned_by_bazel(&p.dir) {
                continue;
            }
            let Some(name) = p.name.clone().or_else(|| p.dir.is_empty().then(|| "(root)".to_string())) else { continue };
            let mut id = format!("npm:{name}");
            if units.iter().any(|u| u.id == id) {
                id = format!("npm:{}/{name}", p.dir);
            }
            units.push(Unit { id, dir: p.dir.clone(), name, kind: ComponentKind::NpmPackage, module: p.name.clone(), manifest: p.manifest.clone(), package: Some(p) });
        }
        // Packages that are projects of their own: a workspace root is not one, and neither is a nameless
        // package.json below the root.
        let package_dirs: Vec<String> =
            project.packages.iter().filter(|p| !(p.dir.is_empty() && p.is_workspace_root()) && (p.name.is_some() || p.dir.is_empty())).map(|p| p.dir.clone()).collect();
        for (dir, config) in &project.tsconfigs {
            // A tsconfig.json in or above a package (such as a workspace root's base config) is no project of its own.
            if package_dirs.iter().any(|p| p.is_empty() || dir.is_empty() || is_under(dir, p) || is_under(p, dir)) || owned_by_bazel(dir) {
                continue;
            }
            let shown = if dir.is_empty() { "." } else { dir.as_str() };
            units.push(Unit {
                id: format!("tsconfig:{shown}"),
                dir: dir.clone(),
                name: if dir.is_empty() { "(root)".to_string() } else { dir.clone() },
                kind: ComponentKind::Tsconfig,
                module: None,
                manifest: config.path.clone(),
                package: None,
            });
        }
        if units.is_empty() {
            return;
        }
        let mut used: BTreeSet<String> = BTreeSet::new();
        for f in files {
            let Some(u) = units.iter().filter(|u| is_under(f, &u.dir)).max_by_key(|u| u.dir.len()) else { continue };
            let rel = strip_dir(f, &u.dir).unwrap_or(f);
            if is_test_path(rel) {
                let id = format!("{}:tests", u.id);
                layout.components.entry(id.clone()).or_insert_with(|| ComponentInfo {
                    id: id.clone(),
                    name: format!("{} tests", u.name),
                    kind: u.kind,
                    module: u.module.clone(),
                    parent: None,
                    is_test: true,
                    layer: None,
                });
                layout.file_component.insert(f.clone(), id);
            } else {
                layout.file_component.insert(f.clone(), u.id.clone());
            }
            used.insert(u.id.clone());
        }
        let ids: HashMap<String, String> = units.iter().filter_map(|u| u.module.clone().map(|m| (m, u.id.clone()))).collect();
        for u in &units {
            // A package without TypeScript files is still a module other packages can depend on.
            if !used.contains(&u.id) && u.package.is_none() {
                continue;
            }
            layout.components.insert(
                u.id.clone(),
                ComponentInfo { id: u.id.clone(), name: u.name.clone(), kind: u.kind, module: u.module.clone(), parent: None, is_test: is_test_path(&u.dir), layer: None },
            );
            if let Some(m) = &u.module {
                layout.module_component.entry(m.clone()).or_insert_with(|| u.id.clone());
            }
            let mut settings: BTreeMap<String, String> = BTreeMap::new();
            if let Some(p) = u.package {
                for dep in p.dependencies(ALL_DEPENDENCY_FIELDS) {
                    if !project.workspace_package(&dep).is_some() {
                        let module = import_name(&dep);
                        layout.externals.entry(format!("ext:{module}")).or_insert(module);
                    }
                }
                for dep in p.dependencies(DEPENDENCY_FIELDS) {
                    let to = match project.workspace_package(&dep) {
                        Some(_) => match ids.get(&dep).or_else(|| layout.module_component.get(&dep)) {
                            Some(id) => id.clone(),
                            None => continue,
                        },
                        None => format!("ext:{}", import_name(&dep)),
                    };
                    if to != u.id {
                        layout.declared_deps.push(DeclaredDep { from: u.id.clone(), to, file: u.manifest.clone(), symbol: format!("dependency {dep}") });
                    }
                }
                for field in ["type", "main", "module", "types", "typings", "exports", "bin", "sideEffects", "engines"] {
                    if let Some(v) = p.field(field) {
                        settings.insert(format!("package.json {field}"), stringify(v));
                    }
                }
            }
            if let Some(config) = project.tsconfigs.get(&u.dir) {
                for (k, v) in &config.own_options {
                    settings.insert(format!("tsconfig {k}"), stringify(v));
                }
            }
            // Registered even when empty, so a project's first setting, or its last, is compared too.
            layout.target_settings.insert(u.id.clone(), TargetSettings { file: u.manifest.clone(), settings, language: "typescript".to_string() });
        }
    }

    /// A Bazel target in a package directory with a named package.json compiles that package.
    fn target_module(&self, source: &SideSource, package_dir: &str) -> Option<String> {
        project(source).packages.iter().find(|p| p.dir == package_dir).and_then(|p| p.name.clone())
    }

    fn resolve_import(&self, source: &SideSource, file: &str, spec: &str) -> Option<Resolved> {
        Some(project(source).resolve(file, spec))
    }
}

/// Pins of the direct dependencies, from lockfile texts by file name.
pub fn pins(direct: &BTreeSet<String>, lockfiles: &[(String, String)]) -> BTreeMap<String, String> {
    let mut versions: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut pin = |name: &str, version: &str| {
        if !direct.contains(name) || version.is_empty() || version.starts_with("link:") || version.starts_with("workspace:") || version.starts_with("file:") {
            return;
        }
        versions.entry(name.to_string()).or_default().insert(version.to_string());
    };
    for (name, text) in lockfiles {
        match name.as_str() {
            "package-lock.json" => {
                let Ok(lock) = serde_json::from_str::<Value>(text) else { continue };
                if let Some(packages) = lock.get("packages").and_then(Value::as_object) {
                    for (key, value) in packages {
                        // Only packages hoisted to the top: "node_modules/react", "node_modules/@scope/pkg".
                        let Some(name) = key.strip_prefix("node_modules/").filter(|n| !n.contains("node_modules/")) else { continue };
                        if let Some(v) = value.get("version").and_then(Value::as_str) {
                            pin(name, v);
                        }
                    }
                }
                if let Some(deps) = lock.get("dependencies").and_then(Value::as_object) {
                    for (name, value) in deps {
                        if let Some(v) = value.get("version").and_then(Value::as_str) {
                            pin(name, v);
                        }
                    }
                }
            }
            "pnpm-lock.yaml" => {
                // pnpm 10 and later put the lockfile of pnpm itself in a first YAML document.
                for doc in serde_yaml_ng::Deserializer::from_str(text) {
                    let Ok(lock) = <serde_yaml_ng::Value as serde::Deserialize>::deserialize(doc) else { continue };
                    let importers: Vec<serde_yaml_ng::Value> = match lock.get("importers").and_then(|i| i.as_mapping()) {
                        Some(m) => m.values().cloned().collect(),
                        None => vec![lock.clone()],
                    };
                    for importer in importers {
                        for field in ALL_DEPENDENCY_FIELDS {
                            let Some(map) = importer.get(*field).and_then(|m| m.as_mapping()) else { continue };
                            for (k, v) in map {
                                let Some(name) = k.as_str() else { continue };
                                let raw = v.get("version").cloned().unwrap_or_else(|| v.clone());
                                let version = match raw {
                                    serde_yaml_ng::Value::String(s) => s,
                                    serde_yaml_ng::Value::Number(n) => n.to_string(),
                                    _ => continue,
                                };
                                pin(name, version.split('(').next().unwrap_or(""));
                            }
                        }
                    }
                }
            }
            "yarn.lock" => {
                let mut names: Vec<String> = Vec::new();
                for line in text.lines().filter(|l| !l.is_empty()) {
                    if !line.starts_with(' ') && line.ends_with(':') && !line.starts_with('#') {
                        // `"react@^18.0.0", react@^18.2.0:` (Classic) or `"react@npm:^18.2.0":` (Berry).
                        names = line[..line.len() - 1]
                            .split(',')
                            .map(|d| {
                                let s = d.trim().trim_matches('"');
                                let at = s.char_indices().skip(1).find(|(_, c)| *c == '@').map(|(i, _)| i).unwrap_or(s.len());
                                s[..at].to_string()
                            })
                            .collect();
                    } else if let Some(rest) = line.trim_start().strip_prefix("version") {
                        if line.starts_with("  ") && !line.starts_with("    ") {
                            let v = rest.trim_start_matches(':').trim().trim_matches('"');
                            for n in &names {
                                pin(n, v);
                            }
                            names.clear();
                        }
                    }
                }
            }
            "bun.lock" => {
                let Some(lock) = project::read_json(text.as_bytes()) else { continue };
                if let Some(packages) = lock.get("packages").and_then(Value::as_object) {
                    for (name, value) in packages {
                        let Some(spec) = value.as_array().and_then(|a| a.first()).and_then(Value::as_str) else { continue };
                        if let Some(at) = spec[1..].rfind('@') {
                            pin(name, &spec[at + 2..]);
                        }
                    }
                }
            }
            _ => {}
        }
    }
    versions.into_iter().map(|(k, v)| (k, v.into_iter().collect::<Vec<_>>().join(", "))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lockfile_pins() {
        let direct: BTreeSet<String> = ["react", "@scope/ui", "typescript", "left"].iter().map(|s| s.to_string()).collect();
        let yarn = "# yarn lockfile v1\n\n\"@scope/ui@^1.0.0\":\n  version \"1.2.0\"\n  resolved \"x\"\n\nreact@^18.0.0, react@^18.2.0:\n  version \"18.2.0\"\n\nleft@1:\n  version \"1.0.0\"\n  dependencies:\n    other \"^2\"\n";
        let pnpm = "lockfileVersion: '9.0'\nimporters:\n  .:\n    devDependencies:\n      typescript:\n        specifier: 5.9.3\n        version: 5.9.3\n";
        let pins = pins(&direct, &[("yarn.lock".into(), yarn.into()), ("pnpm-lock.yaml".into(), pnpm.into())]);
        assert_eq!(pins.get("react").map(String::as_str), Some("18.2.0"));
        assert_eq!(pins.get("@scope/ui").map(String::as_str), Some("1.2.0"));
        assert_eq!(pins.get("left").map(String::as_str), Some("1.0.0"));
        assert_eq!(pins.get("typescript").map(String::as_str), Some("5.9.3"));
        let berry = "__metadata:\n  version: 6\n\n\"react@npm:^18.2.0\":\n  version: 18.3.1\n  resolution: \"react@npm:18.3.1\"\n";
        assert_eq!(super::pins(&direct, &[("yarn.lock".into(), berry.into())]).get("react").map(String::as_str), Some("18.3.1"));
    }

    #[test]
    fn sources_and_settings() {
        let ts = TypeScriptLanguage;
        assert!(ts.is_source("src/a.ts") && ts.is_source("src/A.tsx") && ts.is_source("x.mts") && ts.is_source("types/x.d.ts"));
        assert!(!ts.is_source("src/a.js") && !ts.is_source(".ts"));
        assert_eq!(ts.setting_flag("tsconfig strictNullChecks"), "strictness-changed");
        assert_eq!(ts.setting_flag("tsconfig paths"), "module-resolution-changed");
        assert_eq!(ts.setting_flag("package.json exports"), "package-exports-changed");
        assert!(ts.is_platform_module("node:fs") && ts.is_platform_module("path") && !ts.is_platform_module("react"));
        assert_eq!(ts.package_of_module("lodash", &["@types/lodash".to_string()].into_iter().collect()).as_deref(), Some("lodash"));
    }
}
