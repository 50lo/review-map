//! Kotlin: contract flags, Android manifest contracts, dispatcher isolation, and package-aware conformer
//! lookup. A port of the prototype's `KotlinLanguage.swift`, `KotlinFlags.swift`, `KotlinManifest.swift`,
//! and `KotlinStructure.swift`. Source is parsed without Gradle or the compiler; only indexing builds.

use super::{inherited_names, risk, ConformanceUse, Conformer, Language};
use crate::analyze::{kind_group, Builder, Located, Pair, SideSource};
use crate::model::{ChangeKind, ItemKind, Side};
use crate::parse::kotlin::MAIN_THREAD;
use crate::parse::{Declaration, ParsedFile};
use crate::paths::file_name;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;

pub struct KotlinLanguage;

const UI_TYPES: &[&str] = &["View", "Activity", "Fragment"];
const IMPLICIT_ATTRIBUTES: &[&str] = &[
    "Test", "Before", "After", "BeforeEach", "AfterEach", "BeforeAll", "AfterAll", "BeforeClass", "AfterClass", "ParameterizedTest", "Provides",
    "Binds", "Inject", "Preview",
];

pub fn qualified(package: Option<&str>, name: &str) -> String {
    match package {
        Some(p) if !p.is_empty() => format!("{p}.{name}"),
        _ => name.to_string(),
    }
}

/// Resolves only explicit source names, keeping unrelated packages and nested types distinct.
pub fn resolve_type(ty: &str, file: &ParsedFile, scope: Option<&str>, known: &HashSet<String>) -> Option<String> {
    // Import aliases are normalized in the extractor's supertype traits.
    if ty.contains('.') && known.contains(ty) {
        return Some(ty.to_string());
    }
    let package = file.package_name.as_deref();
    let mut scopes: Vec<&str> = scope.unwrap_or("").split('.').filter(|s| !s.is_empty()).collect();
    while !scopes.is_empty() {
        let mut parts = scopes.clone();
        parts.push(ty);
        let nested = qualified(package, &parts.join("."));
        if known.contains(&nested) {
            return Some(nested);
        }
        scopes.pop();
    }
    // Explicit bindings were already expanded, including aliases, so simple names are not rebound here.
    let local = qualified(package, ty);
    if known.contains(&local) {
        return Some(local);
    }
    let stars: Vec<String> = file.wildcard_imports.iter().map(|p| qualified(Some(p), ty)).filter(|q| known.contains(q)).collect();
    if stars.len() == 1 {
        stars.into_iter().next()
    } else {
        None
    }
}

fn supertypes(d: &Declaration) -> impl Iterator<Item = &str> {
    d.traits.iter().filter_map(|t| t.strip_prefix("supertype:"))
}

fn known_types(files: &BTreeMap<String, Arc<ParsedFile>>) -> HashSet<String> {
    let mut known = HashSet::new();
    for file in files.values().filter(|f| f.language == "kotlin") {
        for d in file.decls.iter().filter(|d| d.is_container()) {
            known.insert(qualified(file.package_name.as_deref(), &d.qualified_name));
        }
    }
    known
}

struct Manifest {
    permissions: BTreeSet<String>,
    exported: BTreeMap<String, String>,
    intents: BTreeSet<String>,
}

const ANDROID_NS: &str = "http://schemas.android.com/apk/res/android";
const MANIFEST_COMPONENTS: &[&str] = &["activity", "activity-alias", "service", "receiver", "provider"];

fn read_manifest(bytes: Option<Vec<u8>>) -> Option<Manifest> {
    let text = String::from_utf8(bytes?).ok()?;
    let doc = roxmltree::Document::parse(&text).ok()?;
    let mut m = Manifest { permissions: BTreeSet::new(), exported: BTreeMap::new(), intents: BTreeSet::new() };
    let android = |n: roxmltree::Node, key: &str| n.attribute((ANDROID_NS, key)).map(str::to_string);
    for n in doc.descendants().filter(|n| n.is_element()) {
        let name = n.tag_name().name();
        if name == "uses-permission" || name == "uses-permission-sdk-23" {
            if let Some(p) = android(n, "name") {
                m.permissions.insert(p);
            }
        }
        if MANIFEST_COMPONENTS.contains(&name) {
            let key = format!("{name}:{}", android(n, "name").unwrap_or_default());
            m.exported.insert(key, android(n, "exported").unwrap_or_else(|| "implicit".to_string()));
        }
        if name == "intent-filter" {
            let owner = n
                .ancestors()
                .skip(1)
                .find(|a| a.is_element() && MANIFEST_COMPONENTS.contains(&a.tag_name().name()))
                .map(|a| format!("{}:{}", a.tag_name().name(), android(a, "name").unwrap_or_default()))
                .unwrap_or_else(|| "application".to_string());
            let mut values: Vec<String> = Vec::new();
            for e in n.descendants().filter(|e| e.is_element()) {
                let mut attrs: Vec<String> = e
                    .attributes()
                    .map(|a| {
                        let key = if a.namespace() == Some(ANDROID_NS) { format!("android:{}", a.name()) } else { a.name().to_string() };
                        format!("{key}={}", a.value())
                    })
                    .collect();
                attrs.sort();
                values.push(format!("{}:{}", e.tag_name().name(), attrs.join("|")));
            }
            values.sort();
            m.intents.insert(format!("{owner}|{}", values.join("|")));
        }
    }
    Some(m)
}

impl Language for KotlinLanguage {
    fn id(&self) -> &'static str {
        "kotlin"
    }

    fn display_name(&self) -> &'static str {
        "Kotlin"
    }

    fn is_source(&self, path: &str) -> bool {
        (path.ends_with(".kt") || path.ends_with(".kts")) && !path.ends_with(".gradle.kts")
    }

    fn generated_patterns(&self) -> &'static [&'static str] {
        &["**/build/generated/**"]
    }

    fn is_platform_module(&self, module: &str) -> bool {
        matches!(module.split('.').next().unwrap_or(""), "kotlin" | "kotlinx" | "java" | "javax" | "android" | "dalvik")
    }

    /// Maven artifacts pinned by rules_jvm_external lockfiles (`*maven_install.json`), as "group:artifact".
    fn pinned_packages(&self, side: &SideSource) -> BTreeMap<String, String> {
        let mut result = BTreeMap::new();
        for path in side.tree.keys().filter(|p| file_name(p).ends_with("maven_install.json")) {
            let Some(bytes) = side.bytes(path) else { continue };
            let Ok(obj) = serde_json::from_slice::<serde_json::Value>(&bytes) else { continue };
            // Lockfile v2: {"artifacts": {"group:artifact": {"version": "1.2.3", …}}}.
            if let Some(artifacts) = obj.get("artifacts").and_then(|a| a.as_object()) {
                for (name, info) in artifacts {
                    if let Some(v) = info.get("version").and_then(|v| v.as_str()) {
                        result.entry(name.clone()).or_insert_with(|| v.to_string());
                    }
                }
            }
            // Lockfile v1: {"dependency_tree": {"dependencies": [{"coord": "group:artifact:version"}]}}.
            if let Some(deps) = obj.get("dependency_tree").and_then(|t| t.get("dependencies")).and_then(|d| d.as_array()) {
                for dep in deps {
                    let Some(coord) = dep.get("coord").and_then(|c| c.as_str()) else { continue };
                    let parts: Vec<&str> = coord.split(':').collect();
                    if parts.len() >= 3 {
                        result.entry(format!("{}:{}", parts[0], parts[1])).or_insert_with(|| parts[parts.len() - 1].to_string());
                    }
                }
            }
        }
        result
    }

    fn contract_flags(&self, builder: &Builder, pairs: &[usize]) -> HashMap<usize, Vec<String>> {
        flags(builder, pairs)
    }

    fn contract_file(&self, path: &str) -> Option<(String, String)> {
        (file_name(path) == "AndroidManifest.xml").then(|| (path.to_string(), "android-manifest-changed".to_string()))
    }

    fn contract_file_flags(&self, key: &str, _flag: &str, base: &SideSource, head: &SideSource) -> Vec<String> {
        let (Some(b), Some(h)) = (read_manifest(base.bytes(key)), read_manifest(head.bytes(key))) else { return Vec::new() };
        let mut flags = Vec::new();
        if h.permissions.difference(&b.permissions).next().is_some() {
            flags.push("permission-added".to_string());
        }
        if b.permissions.difference(&h.permissions).next().is_some() {
            flags.push("permission-removed".to_string());
        }
        if b.exported != h.exported {
            flags.push("exported-components-changed".to_string());
        }
        if b.intents != h.intents {
            flags.push("intent-filters-changed".to_string());
        }
        flags
    }

    fn setting_flag(&self, key: &str) -> String {
        let flag = if key.contains("minSdk") || key.contains("min_sdk") {
            "min-sdk-changed"
        } else if key.contains("targetSdk") || key.contains("target_sdk") {
            "target-sdk-changed"
        } else if key.contains("compileSdk") || key.contains("compile_sdk") {
            "compile-sdk-changed"
        } else if key.contains("jvmTarget") || key.contains("jvm_target") || key.contains("jvmToolchain") {
            "jvm-target-changed"
        } else if key.contains("kotlin") {
            "kotlin-version-changed"
        } else {
            "settings-changed"
        };
        flag.to_string()
    }

    fn flag_risk(&self, flag: &str, _is_interface: bool) -> f64 {
        if matches!(flag, "api-added" | "compile-sdk-changed" | "jvm-target-changed" | "kotlin-version-changed" | "settings-changed") {
            risk::MEDIUM
        } else {
            risk::HIGH
        }
    }

    fn is_view_code(&self, decl: &Declaration, inherits: &HashSet<String>) -> bool {
        decl.attributes.iter().any(|a| a == "Composable") || UI_TYPES.iter().any(|t| inherits.contains(*t))
    }

    fn is_public_api(&self, decl: &Declaration, enclosing: &[&Declaration]) -> bool {
        decl.access.as_deref() == Some("public") && enclosing.iter().all(|d| d.access.as_deref() == Some("public"))
    }

    /// JVM entry points, operators, and declarations explicitly registered with common runtimes.
    fn is_implicitly_called(&self, decl: &Declaration) -> bool {
        if decl.kind == ItemKind::Func && (decl.name == "main" || decl.modifiers.iter().any(|m| m == "operator")) {
            return true;
        }
        decl.attributes.iter().any(|a| IMPLICIT_ATTRIBUTES.contains(&a.as_str()))
    }

    /// Uses Kotlin package/import identity before matching members of the actual implementing class.
    fn conformers(&self, interface: &Pair, requirement: Option<&Pair>, builder: &Builder, use_: ConformanceUse) -> Vec<Conformer> {
        let side = if interface.head.is_none() { builder.base } else { builder.head };
        let iloc = interface.any();
        let Some(interface_file) = side.files().get(&*iloc.file) else { return Vec::new() };
        let wanted = qualified(interface_file.package_name.as_deref(), &iloc.decl().qualified_name);
        let known = known_types(builder.head.files());
        let member = requirement.and_then(|r| r.head.as_ref()).map(|h| h.decl());
        let mut result = Vec::new();
        for (path, file) in builder.head.files() {
            if file.language != "kotlin" {
                continue;
            }
            let Some(component) = builder.head.layout.file_component.get(path) else { continue };
            if use_ == ConformanceUse::Check && **component != *iloc.component && !builder.has_edge(Side::Head, component, &iloc.component) {
                continue;
            }
            for (index, declaration) in file.decls.iter().enumerate() {
                if !declaration.is_container() {
                    continue;
                }
                if !supertypes(declaration).any(|s| resolve_type(s, file, declaration.scope.as_deref(), &known).as_deref() == Some(wanted.as_str())) {
                    continue;
                }
                let file_key: Arc<str> = Arc::from(path.as_str());
                let comp_key: Arc<str> = Arc::from(component.as_str());
                let located = Located { parsed: file.clone(), file: file_key.clone(), index, component: comp_key.clone() };
                let mut implementations = Vec::new();
                if let Some(member) = member {
                    for (member_index, candidate) in file.decls.iter().enumerate() {
                        if candidate.parent_index == Some(index) && candidate.name == member.name && kind_group(candidate.kind) == kind_group(member.kind) {
                            implementations.push(Located { parsed: file.clone(), file: file_key.clone(), index: member_index, component: comp_key.clone() });
                        }
                    }
                }
                result.push(Conformer { declaration: located, implementations });
            }
        }
        result
    }

    fn isolation(&self, file: &ParsedFile, line: u32) -> Option<String> {
        if let Some(region) =
            file.isolation_regions.iter().filter(|r| r.start_line <= line && line <= r.end_line).min_by_key(|r| r.end_byte - r.start_byte)
        {
            // A non-main dispatcher deliberately clears inherited main-thread isolation.
            return region.isolation.clone();
        }
        let enclosing = file.enclosing_decl(line)?;
        for declaration in std::iter::once(enclosing).chain(file.enclosing_declarations(enclosing)) {
            if declaration.attributes.iter().any(|a| a == "MainThread" || a == "UiThread") {
                return Some(MAIN_THREAD.to_string());
            }
            if declaration.is_container() && inherited_names(declaration).any(|n| UI_TYPES.contains(&n)) {
                return Some(MAIN_THREAD.to_string());
            }
        }
        None
    }
}

// MARK: Contract flags

fn is_public(builder: &Builder, location: Option<&Located>) -> bool {
    let Some(location) = location else { return false };
    let enclosing = location.parsed.enclosing_declarations(location.decl());
    KotlinLanguage.is_public_api(location.decl(), &enclosing) && {
        let _ = builder;
        true
    }
}

fn visibility_narrowed(base: Option<&str>, head: Option<&str>) -> bool {
    let (base, head) = (base.unwrap_or("public"), head.unwrap_or("public"));
    // Internal and protected expose different callers; either transition removes access for some.
    base != head && head != "public" && base != "private"
}

fn nullable(d: &Declaration) -> BTreeSet<&str> {
    d.traits.iter().filter(|t| t.starts_with("nullable:")).map(String::as_str).collect()
}

fn has_modifier(modifier: &str, d: &Declaration) -> bool {
    let has = |m: &str| d.modifiers.iter().any(|x| x == m);
    if modifier == "final" {
        return has("final")
            || (!has("open") && !has("abstract") && !has("sealed") && !has("override") && d.kind != ItemKind::Protocol && d.parent_kind != Some(ItemKind::Protocol) && !d.in_protocol);
    }
    has(modifier)
}

fn annotations<'d>(d: &'d Declaration, names: &[&str]) -> BTreeSet<&'d str> {
    d.traits
        .iter()
        .filter(|t| {
            let Some(annotation) = t.strip_prefix("annotation:") else { return false };
            let head = annotation.split('(').next().unwrap_or("");
            let name = head.split(|c: char| c == '.' || c == ':' || c == '@' || c.is_whitespace()).filter(|s| !s.is_empty()).last().unwrap_or("");
            names.contains(&name)
        })
        .map(String::as_str)
        .collect()
}

fn serialization(d: &Declaration) -> BTreeSet<&str> {
    annotations(d, &["Serializable", "SerialName", "Json"])
}

fn persistence(d: &Declaration) -> BTreeSet<&str> {
    annotations(d, &["Entity", "ColumnInfo"])
}

fn flags(b: &Builder, indices: &[usize]) -> HashMap<usize, Vec<String>> {
    let mut out: HashMap<usize, BTreeSet<String>> = HashMap::new();
    let known = [known_types(b.base.files()), known_types(b.head.files())];
    let known_of = |s: Side| if s == Side::Base { &known[0] } else { &known[1] };
    let supertypes_of = |location: Option<&Located>, side: Side| -> BTreeSet<String> {
        let Some(location) = location else { return BTreeSet::new() };
        supertypes(location.decl()).filter_map(|s| resolve_type(s, &location.parsed, location.decl().scope.as_deref(), known_of(side))).collect()
    };
    let parent_of = |p: &Pair| -> Option<usize> {
        p.head.as_ref().and_then(|h| b.parent_pair(h, Side::Head)).or_else(|| p.base.as_ref().and_then(|x| b.parent_pair(x, Side::Base)))
    };
    for &i in indices {
        let p = &b.pairs[i];
        let d = p.any().decl();
        let base = p.base.as_ref().map(|l| l.decl());
        let head = p.head.as_ref().map(|l| l.decl());
        let added = base.is_none();
        let removed = head.is_none();
        let structural = added || removed || p.changes.contains(&ChangeKind::Signature);
        let parent = parent_of(p);
        let parent_both = parent.map(|pp| b.pairs[pp].base.is_some() && b.pairs[pp].head.is_some()).unwrap_or(false);
        let mut own: Vec<String> = Vec::new();
        let mut to_parent: Vec<(usize, String)> = Vec::new();
        let mut member = |name: String, own: &mut Vec<String>| {
            if let (Some(pp), true) = (parent, parent_both) {
                own.push(name.clone());
                to_parent.push((pp, name));
            }
        };
        if is_public(b, p.base.as_ref()) || is_public(b, p.head.as_ref()) {
            if added {
                own.push("api-added".into());
            } else if removed {
                own.push("api-removed".into());
            } else if p.changes.contains(&ChangeKind::Signature) {
                own.push("api-signature-changed".into());
            }
        }
        if d.kind == ItemKind::Case && (added || removed) {
            member(format!("enum-entry-{}", if added { "added" } else { "removed" }), &mut own);
        }
        let gained_requirement = base.map(|x| !x.in_protocol).unwrap_or(false) && head.map(|x| x.in_protocol).unwrap_or(false);
        if d.in_protocol && (structural || gained_requirement) {
            member(format!("interface-member-{}", if added { "added" } else if removed { "removed" } else { "changed" }), &mut own);
        }
        if d.traits.contains("constructor-property") && (structural || p.changes.contains(&ChangeKind::Modifiers)) {
            if let Some(pp) = parent {
                let owner = &b.pairs[pp];
                let is_data = [owner.base.as_ref(), owner.head.as_ref()].into_iter().flatten().any(|l| l.decl().modifiers.iter().any(|m| m == "data"));
                if is_data {
                    member("data-class-shape-changed".into(), &mut own);
                }
            }
        }
        if let (Some(base), Some(head)) = (base, head) {
            let data = |x: &Declaration| x.modifiers.iter().any(|m| m == "data");
            if data(base) || data(head) {
                let shape = |x: &Declaration| -> Vec<String> { x.traits.iter().filter(|t| t.starts_with("constructor-shape:")).cloned().collect() };
                if data(base) != data(head) || shape(base) != shape(head) {
                    own.push("data-class-shape-changed".into());
                }
            }
            if visibility_narrowed(base.access.as_deref(), head.access.as_deref()) {
                own.push("visibility-narrowed".into());
            }
            if base.is_async != head.is_async {
                own.push(if head.is_async { "suspend-added" } else { "suspend-removed" }.into());
            }
            if nullable(base) != nullable(head) {
                own.push("nullability-changed".into());
            }
            for modifier in ["open", "final", "abstract"] {
                if has_modifier(modifier, base) != has_modifier(modifier, head) {
                    own.push(format!("{modifier}-{}", if has_modifier(modifier, head) { "added" } else { "removed" }));
                }
            }
            if serialization(base) != serialization(head) {
                own.push("serialized-shape-changed".into());
            }
            if persistence(base) != persistence(head) {
                own.push("persisted-shape-changed".into());
            }
        }
        if structural || p.changes.contains(&ChangeKind::Modifiers) {
            type Attrs = for<'d> fn(&'d Declaration) -> BTreeSet<&'d str>;
            let kinds: [(&str, Attrs); 2] = [("serialized-shape-changed", serialization), ("persisted-shape-changed", persistence)];
            for (name, attributes) in kinds {
                if [base, head].into_iter().flatten().any(|x| !attributes(x).is_empty()) {
                    own.push(name.into());
                }
                if d.kind == ItemKind::Var {
                    let mut ancestor = parent;
                    while let Some(index) = ancestor {
                        let owner = &b.pairs[index];
                        if owner.base.is_some()
                            && owner.head.is_some()
                            && [owner.base.as_ref(), owner.head.as_ref()].into_iter().flatten().any(|l| !attributes(l.decl()).is_empty())
                        {
                            own.push(name.into());
                            to_parent.push((index, name.into()));
                        }
                        ancestor = parent_of(owner);
                    }
                }
            }
        }
        // Sealed subclasses need not be nested in their sealed parent.
        for (side, location, other) in [(Side::Base, p.base.as_ref(), p.head.as_ref()), (Side::Head, p.head.as_ref(), p.base.as_ref())] {
            let Some(location) = location else { continue };
            let theirs = supertypes_of(other, side.other());
            let changed_parents: BTreeSet<String> = supertypes_of(Some(location), side).into_iter().filter(|s| !theirs.contains(s)).collect();
            if changed_parents.is_empty() {
                continue;
            }
            for &ancestor in indices {
                let ty = &b.pairs[ancestor];
                if ty.base.is_none() || ty.head.is_none() {
                    continue;
                }
                let Some(owner) = ty.at(side) else { continue };
                if !owner.decl().modifiers.iter().any(|m| m == "sealed") {
                    continue;
                }
                let owner_name = qualified(owner.parsed.package_name.as_deref(), &owner.decl().qualified_name);
                if !changed_parents.contains(&owner_name) || owner.component != location.component || owner.parsed.package_name != location.parsed.package_name {
                    continue;
                }
                let name = format!("sealed-subclass-{}", if side == Side::Head { "added" } else { "removed" });
                own.push(name.clone());
                to_parent.push((ancestor, name));
            }
        }
        out.entry(i).or_default().extend(own);
        for (pp, name) in to_parent {
            out.entry(pp).or_default().insert(name);
        }
    }
    out.into_iter().map(|(k, v)| (k, v.into_iter().collect())).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_flags() {
        let base = br#"<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="a.INTERNET"/><application><activity android:name=".Main" android:exported="false"/></application></manifest>"#;
        let head = br#"<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="a.INTERNET"/><uses-permission android:name="a.CAMERA"/><application><activity android:name=".Main" android:exported="true"><intent-filter><action android:name="x.VIEW"/></intent-filter></activity></application></manifest>"#;
        let b = read_manifest(Some(base.to_vec())).unwrap();
        let h = read_manifest(Some(head.to_vec())).unwrap();
        assert!(h.permissions.contains("a.CAMERA") && !b.permissions.contains("a.CAMERA"));
        assert_ne!(b.exported, h.exported);
        assert_eq!(h.intents.len(), 1);
    }

    #[test]
    fn visibility() {
        assert!(visibility_narrowed(Some("public"), Some("internal")));
        assert!(!visibility_narrowed(Some("private"), Some("internal")));
        assert!(!visibility_narrowed(Some("internal"), Some("public")));
    }
}
