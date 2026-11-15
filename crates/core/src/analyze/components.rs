//! How one side's source tree is cut into components: Bazel targets when the build graph is known, Bazel
//! packages before that, and top-level folders for files outside any workspace. Large components are
//! split by folder and `reviewmap.yml` rules override the result, as in the prototype's `Components.swift`.

use super::SideSource;
use crate::bazel::graph::{external_name, SideGraph, TargetNode, WorkspaceGraph};
use crate::bazel::{package_of, workspace_of};
use crate::config::{Config, Glob};
use crate::lang::Language;
use crate::model::{ComponentKind, Warning};
use crate::paths::{is_test_path, join, parent, strip_dir};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};

#[derive(Clone, Debug, PartialEq)]
pub struct ComponentInfo {
    pub id: String,
    pub name: String,
    pub kind: ComponentKind,
    pub module: Option<String>,
    pub parent: Option<String>,
    pub is_test: bool,
    pub layer: Option<String>,
}

/// A dependency a BUILD file declares, from one component to another or to an external package.
#[derive(Clone, Debug, PartialEq)]
pub struct DeclaredDep {
    pub from: String,
    pub to: String,
    /// The BUILD file, repo-relative.
    pub file: String,
    /// "dependency //lib:lib".
    pub symbol: String,
}

/// Target-level build settings that change how code compiles, and the BUILD file that sets them.
#[derive(Clone, Debug, PartialEq)]
pub struct TargetSettings {
    pub file: String,
    pub settings: BTreeMap<String, String>,
    pub language: String,
}

#[derive(Clone, Debug, Default)]
pub struct ComponentLayout {
    pub components: BTreeMap<String, ComponentInfo>,
    pub file_component: BTreeMap<String, String>,
    /// Module name -> the target-level component that owns it.
    pub module_component: BTreeMap<String, String>,
    pub declared_deps: Vec<DeclaredDep>,
    /// Component id -> its build settings.
    pub target_settings: BTreeMap<String, TargetSettings>,
    /// External component id -> name.
    pub externals: BTreeMap<String, String>,
    /// Files that several targets list, with every target that lists them (labels with their workspace).
    pub shared_files: BTreeMap<String, Vec<String>>,
    pub warnings: Vec<Warning>,
}

impl ComponentLayout {
    /// The target a split folder belongs to.
    pub fn root_of<'a>(&'a self, id: &'a str) -> &'a str {
        let mut cur = id;
        while let Some(p) = self.components.get(cur).and_then(|c| c.parent.as_deref()) {
            cur = p;
        }
        cur
    }
}

/// The id of a target's component: its label, prefixed by its workspace when that is not the repo root.
pub fn target_id(workspace: &str, label: &str) -> String {
    if workspace.is_empty() {
        label.to_string()
    } else {
        format!("{workspace}{label}")
    }
}

/// "//app/checkout:checkout" -> "checkout"; "//app:AppLib" -> "AppLib".
fn target_name(label: &str) -> &str {
    label.rsplit(':').next().unwrap_or(label)
}

const DEP_HOPS: usize = 6;

pub fn build(
    source: &SideSource,
    languages: &[&'static dyn Language],
    config: &Config,
    workspaces: &[String],
    graph: Option<&SideGraph>,
) -> ComponentLayout {
    let mut layout = ComponentLayout::default();
    let files: Vec<&String> = source.files.keys().collect();

    // 1. Bazel targets, for the workspaces whose graph is known.
    if let Some(graph) = graph {
        for ws in &graph.workspaces {
            add_targets(source, languages, ws, &mut layout);
        }
    }

    // 2. Bazel packages, for files in a workspace that no target claimed (or whose graph is not known yet).
    for f in &files {
        if layout.file_component.contains_key(*f) {
            continue;
        }
        let Some(ws) = workspace_of(workspaces, f) else { continue };
        let Some(pkg) = package_of(&source.tree, ws, f) else { continue };
        let id = format!("pkg:{}", if pkg.is_empty() { "." } else { pkg.as_str() });
        layout.components.entry(id.clone()).or_insert_with(|| {
            let rel = strip_dir(&pkg, ws).unwrap_or(if pkg == ws { "" } else { pkg.as_str() });
            let name = if rel.is_empty() {
                if ws.is_empty() { "(root)".to_string() } else { ws.to_string() }
            } else {
                rel.to_string()
            };
            ComponentInfo { id: id.clone(), name, kind: ComponentKind::BazelPackage, module: None, parent: None, is_test: is_test_path(&pkg), layer: None }
        });
        layout.file_component.insert((*f).clone(), id);
    }

    // 3. Remaining files: folder components by top-level directory.
    for f in &files {
        if layout.file_component.contains_key(*f) {
            continue;
        }
        let top = f.split('/').next().filter(|_| f.contains('/')).unwrap_or(".");
        let id = format!("folder:{top}");
        layout.components.entry(id.clone()).or_insert_with(|| ComponentInfo {
            id: id.clone(),
            name: if top == "." { "(root)".to_string() } else { top.to_string() },
            kind: ComponentKind::Folder,
            module: None,
            parent: None,
            is_test: is_test_path(top),
            layer: None,
        });
        layout.file_component.insert((*f).clone(), id);
    }

    // 4. Split large components by folder.
    let mut by_component: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (f, c) in &layout.file_component {
        by_component.entry(c.clone()).or_default().push(f.clone());
    }
    for (id, comp_files) in by_component {
        let Some(info) = layout.components.get(&id).cloned() else { continue };
        split(&info, &comp_files, 1, config, &mut layout);
    }

    // 5. reviewmap.yml rules override everything.
    if let Some(rules) = config.components.as_ref().filter(|r| !r.is_empty()) {
        let matchers: Vec<(&crate::config::ComponentRule, Vec<Glob>)> = rules.iter().map(|r| (r, r.paths.iter().map(|p| Glob::new(p)).collect())).collect();
        for f in &files {
            let Some((rule, _)) = matchers.iter().find(|(_, globs)| globs.iter().any(|g| g.matches(f))) else { continue };
            let id = format!("cfg:{}", rule.name);
            let original = layout.file_component.get(*f).and_then(|c| layout.components.get(c)).cloned();
            layout.components.entry(id.clone()).or_insert_with(|| ComponentInfo {
                id: id.clone(),
                name: rule.name.clone(),
                kind: ComponentKind::Folder,
                module: original.as_ref().and_then(|o| o.module.clone()),
                parent: None,
                is_test: original.as_ref().map(|o| o.is_test).unwrap_or(false),
                layer: rule.layer.clone(),
            });
            layout.file_component.insert((*f).clone(), id);
        }
    }

    // 6. Layers that name components take them (and their split folders) unless a rule already gave one.
    for layer in config.layers.iter().flatten() {
        let globs: Vec<Glob> = layer.components.iter().flatten().map(|p| Glob::new(p)).collect();
        if globs.is_empty() {
            continue;
        }
        for info in layout.components.values_mut() {
            if info.layer.is_none() && info.kind != ComponentKind::External && globs.iter().any(|g| g.matches(&info.name)) {
                info.layer = Some(layer.name.clone());
            }
        }
    }
    let ids: Vec<String> = layout.components.keys().cloned().collect();
    for id in ids {
        if layout.components[&id].layer.is_some() {
            continue;
        }
        let mut p = layout.components[&id].parent.clone();
        while let Some(pid) = p {
            let Some(parent_info) = layout.components.get(&pid) else { break };
            if let Some(l) = parent_info.layer.clone() {
                layout.components.get_mut(&id).unwrap().layer = Some(l);
                break;
            }
            p = parent_info.parent.clone();
        }
    }

    // A module root left with no files and no children (all its files moved by config rules) hands its
    // role to the component holding most of the module's files.
    let used: HashSet<String> = layout.file_component.values().cloned().collect();
    let parents: HashSet<String> = layout.components.values().filter_map(|c| c.parent.clone()).collect();
    let roots: Vec<(String, String)> = layout.module_component.iter().map(|(m, c)| (m.clone(), c.clone())).collect();
    for (module, root_id) in roots {
        if used.contains(&root_id) || parents.contains(&root_id) {
            continue;
        }
        let mut counts: BTreeMap<String, usize> = BTreeMap::new();
        for c in layout.file_component.values() {
            if layout.components.get(c).and_then(|i| i.module.as_deref()) == Some(module.as_str()) {
                *counts.entry(c.clone()).or_default() += 1;
            }
        }
        // Most files first; ties go to the smaller id.
        let Some(best) = counts.iter().max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0))).map(|(k, _)| k.clone()) else { continue };
        layout.module_component.insert(module, best.clone());
        for dep in layout.declared_deps.iter_mut().filter(|d| d.from == root_id) {
            dep.from = best.clone();
        }
    }
    // Drop components that ended up with no files, except module roots and the ends of declared dependencies.
    let module_roots: HashSet<String> = layout.module_component.values().cloned().collect();
    let dep_ends: HashSet<String> = layout.declared_deps.iter().flat_map(|d| [d.from.clone(), d.to.clone()]).collect();
    layout.components.retain(|id, _| used.contains(id) || parents.contains(id) || module_roots.contains(id) || dep_ends.contains(id));
    layout.declared_deps.retain(|d| layout.components.contains_key(&d.from) && (layout.components.contains_key(&d.to) || d.to.starts_with("ext:")));
    layout
}

/// Adds the targets of one workspace that own source files of a supported language, their declared
/// dependencies on each other and on external packages, and their build settings.
fn add_targets(source: &SideSource, languages: &[&'static dyn Language], ws: &WorkspaceGraph, layout: &mut ComponentLayout) {
    let wsdir = ws.workspace.as_str();
    // Source files per target, repo-relative, limited to the parsed files of this side.
    let mut owned: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    let mut owners: BTreeMap<String, Vec<&str>> = BTreeMap::new();
    for (label, t) in &ws.targets {
        if t.external {
            continue;
        }
        for src in &t.srcs {
            let path = join(wsdir, src);
            if source.files.contains_key(&path) {
                owned.entry(label.as_str()).or_default().push(path.clone());
                owners.entry(path).or_default().push(label.as_str());
            }
        }
    }
    let is_test_target = |t: &TargetNode| t.testonly || t.rule_class.ends_with("_test") || is_test_path(&t.label.replace(':', "/").replace("//", ""));
    let mut shared = 0usize;
    for (path, list) in &owners {
        // The owner a shared file is shown under: a non-test target first, then the one in the file's own
        // package, then the smallest label. Every owner is kept for index resolution.
        let dir = strip_dir(parent(path), wsdir).unwrap_or(parent(path));
        let pick = list
            .iter()
            .copied()
            .min_by_key(|l| {
                let t = &ws.targets[*l];
                let package = l.trim_start_matches("//").split(':').next().unwrap_or("");
                (is_test_target(t), package != dir, l.to_string())
            })
            .unwrap();
        layout.file_component.insert(path.clone(), target_id(wsdir, pick));
        if list.len() > 1 {
            shared += 1;
            layout.shared_files.insert(path.clone(), list.iter().map(|l| target_id(wsdir, l)).collect());
        }
    }
    if shared > 0 {
        let first: Vec<&str> = layout.shared_files.keys().take(3).map(String::as_str).collect();
        layout.warnings.push(Warning::new(
            "shared-sources",
            format!(
                "{shared} source file{} belong to several Bazel targets{}; each is shown under one target (a non-test target in its own package first), and its references are resolved for every target that compiles it (first: {}).",
                if shared == 1 { "" } else { "s" },
                if wsdir.is_empty() { String::new() } else { format!(" in {wsdir}") },
                first.join(", ")
            ),
        ));
    }

    // Display names: the target's name, or "package:name" when two code targets share a name.
    let mut name_count: HashMap<&str, usize> = HashMap::new();
    for label in owned.keys() {
        *name_count.entry(target_name(label)).or_default() += 1;
    }
    for (label, files) in &owned {
        let t = &ws.targets[*label];
        let id = target_id(wsdir, label);
        let name = if name_count[target_name(label)] > 1 { label.trim_start_matches("//").to_string() } else { target_name(label).to_string() };
        let language = languages.iter().find(|l| files.iter().any(|f| l.is_source(f))).map(|l| l.id()).unwrap_or("swift");
        let module = if language == "swift" { t.module_name.clone() } else { None };
        layout.components.insert(
            id.clone(),
            ComponentInfo { id: id.clone(), name, kind: ComponentKind::BazelTarget, module: module.clone(), parent: None, is_test: is_test_target(t), layer: None },
        );
        if let Some(m) = module {
            layout.module_component.entry(m).or_insert_with(|| id.clone());
        }
        if !t.settings.is_empty() {
            layout
                .target_settings
                .insert(id.clone(), TargetSettings { file: join(wsdir, &t.build_file), settings: t.settings.clone(), language: language.to_string() });
        }
    }

    // Declared dependencies between code targets, through targets that own no analyzed source
    // (applications, aliases, resource bundles, libraries of other languages), and on external packages.
    for label in owned.keys() {
        let from = target_id(wsdir, label);
        let t = &ws.targets[*label];
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        let mut queue: VecDeque<(&str, &str, usize)> = t.deps.iter().map(|d| (d.as_str(), d.as_str(), 1usize)).collect();
        let mut found: BTreeSet<(String, String)> = BTreeSet::new();
        while let Some((dep, first_hop, hops)) = queue.pop_front() {
            if !seen.insert(dep) {
                continue;
            }
            let node = ws.targets.get(dep);
            let external = node.map(|n| n.external).unwrap_or(dep.starts_with('@'));
            if external {
                // Only external packages a dependency attribute names directly count: the ones behind
                // them are those packages' business.
                if hops == 1 {
                    let name = external_name(dep);
                    let id = format!("ext:{name}");
                    layout.externals.insert(id.clone(), name);
                    found.insert((id, dep.to_string()));
                }
                continue;
            }
            if owned.contains_key(dep) {
                found.insert((target_id(wsdir, dep), first_hop.to_string()));
                continue;
            }
            if let (Some(node), true) = (node, hops < DEP_HOPS) {
                for next in &node.deps {
                    queue.push_back((next.as_str(), first_hop, hops + 1));
                }
            }
        }
        for (to, via) in found {
            if to != from {
                layout.declared_deps.push(DeclaredDep { from: from.clone(), to, file: join(wsdir, &t.build_file), symbol: format!("dependency {via}") });
            }
        }
    }
}

fn split(parent_info: &ComponentInfo, files: &[String], depth: usize, config: &Config, layout: &mut ComponentLayout) {
    if files.len() <= config.split_threshold() || depth > config.split_max_depth() {
        return;
    }
    // Root: the common directory, descending while one folder holds at least 80% of the files
    // (a few stray files elsewhere shouldn't push the root up to the repo root).
    let mut root_dir = common_dir(files);
    loop {
        let mut counts: BTreeMap<String, usize> = BTreeMap::new();
        for f in files {
            let Some(rel) = strip_dir(f, &root_dir) else { continue };
            let parts: Vec<&str> = rel.split('/').collect();
            if parts.len() > 2 {
                *counts.entry(parts[0].to_string()).or_default() += 1;
            }
        }
        let Some((top, n)) = counts.iter().max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0))) else { break };
        if (*n as f64) < 0.8 * files.len() as f64 {
            break;
        }
        root_dir = join(&root_dir, top);
    }
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for f in files {
        let Some(rel) = strip_dir(f, &root_dir) else { continue };
        let parts: Vec<&str> = rel.split('/').collect();
        if parts.len() > 1 {
            groups.entry(parts[0].to_string()).or_default().push(f.clone());
        }
    }
    // Splitting only helps when there are at least two folders.
    if groups.len() < 2 {
        return;
    }
    for (folder, gfiles) in groups {
        let id = format!("{}/{}", parent_info.id, folder);
        let info = ComponentInfo {
            id: id.clone(),
            name: format!("{}/{}", parent_info.name, folder),
            kind: ComponentKind::Folder,
            module: parent_info.module.clone(),
            parent: Some(parent_info.id.clone()),
            is_test: parent_info.is_test || is_test_path(&folder),
            layer: parent_info.layer.clone(),
        };
        layout.components.insert(id.clone(), info.clone());
        for f in &gfiles {
            layout.file_component.insert(f.clone(), id.clone());
        }
        split(&info, &gfiles, depth + 1, config, layout);
    }
}

fn common_dir(files: &[String]) -> String {
    let Some(first) = files.first() else { return String::new() };
    let mut prefix: Vec<&str> = parent(first).split('/').filter(|s| !s.is_empty()).collect();
    for f in &files[1..] {
        let dirs: Vec<&str> = parent(f).split('/').filter(|s| !s.is_empty()).collect();
        let n = prefix.iter().zip(dirs.iter()).take_while(|(a, b)| a == b).count();
        prefix.truncate(n);
    }
    prefix.join("/")
}
