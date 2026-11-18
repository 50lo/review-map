//! What a language plugs into the language-neutral core: which files it parses, its platform modules and
//! lockfile pins, its contract flags and their risk weights, its non-code contracts, public-API
//! classification, conformer discovery, reference isolation, and, for languages that have them, their own
//! components and import resolution. Parsing and indexing are driven by the session, because they run in
//! stages.

pub mod kotlin;
pub mod swift;
pub mod typescript;

pub use typescript::project::Resolved as ImportTarget;

use crate::analyze::components::ComponentLayout;
use crate::analyze::{conformance_name, kind_group, Builder, Located, Mode, Pair, SideSource};
use crate::model::{ItemKind, Side};
use crate::parse::{Declaration, ParsedFile};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

/// The two existing consumers use different visibility and member matching rules.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum ConformanceUse {
    Check,
    Context,
}

/// A head conformer and its implementations of the requested requirement. An empty implementation
/// list means the requirement is missing; the core never rematches methods the language rejected.
pub struct Conformer {
    pub declaration: Located,
    pub implementations: Vec<Located>,
}

/// Risk weights of region signals.
pub mod risk {
    pub const HIGH: f64 = 0.6;
    pub const MEDIUM: f64 = 0.3;
    pub const BASE: f64 = 0.1;
}

pub trait Language: Sync + Send {
    /// Short id, also the prefix of its contract flags ("swift" makes "swift:codable-shape").
    fn id(&self) -> &'static str;
    /// Name used in prose.
    fn display_name(&self) -> &'static str;
    /// Source files the language parses.
    fn is_source(&self, path: &str) -> bool;
    /// Glob patterns of generated source files, on top of the ones in reviewmap.yml.
    fn generated_patterns(&self) -> &'static [&'static str];
    /// Whether importing `module` is importing the platform: neither an edge nor a warning.
    fn is_platform_module(&self, module: &str) -> bool;
    /// Versions of third-party packages pinned by the language's lockfiles, by package identity.
    fn pinned_packages(&self, side: &SideSource) -> BTreeMap<String, String>;
    /// The pinned package a module belongs to, for modules the manifests list by name only.
    fn package_of_module(&self, _module: &str, _pinned: &BTreeSet<String>) -> Option<String> {
        None
    }

    /// Contract flags of the language's matched declarations (indices into `builder.pairs`), without the prefix.
    fn contract_flags(&self, builder: &Builder, pairs: &[usize]) -> HashMap<usize, Vec<String>>;
    /// A non-code file that is part of a contract: the path it is reported under, and its flag.
    fn contract_file(&self, path: &str) -> Option<(String, String)>;
    /// More flags for a contract file that exists at both sides, read from its two versions.
    fn contract_file_flags(&self, key: &str, flag: &str, base: &SideSource, head: &SideSource) -> Vec<String>;
    /// The flag of a changed target build setting.
    fn setting_flag(&self, key: &str) -> String;
    /// The risk weight of one of the language's contract flags.
    fn flag_risk(&self, flag: &str, is_interface: bool) -> f64;
    /// View code, where control flow is mostly layout.
    fn is_view_code(&self, decl: &Declaration, inherits: &HashSet<String>) -> bool;

    /// Whether this declaration is public API. `enclosing` is its parent chain, innermost first.
    fn is_public_api(&self, decl: &Declaration, enclosing: &[&Declaration]) -> bool;
    /// Whether a runtime, framework, or language convention may call this declaration without naming it.
    fn is_implicitly_called(&self, decl: &Declaration) -> bool;
    /// Head declarations that conform to the matched interface, with their implementations of `requirement`.
    fn conformers(&self, interface: &Pair, requirement: Option<&Pair>, builder: &Builder, use_: ConformanceUse) -> Vec<Conformer> {
        default_conformers(interface, requirement, builder, use_)
    }
    /// The isolation of a reference at a 1-based line, from the language's parsed file facts.
    fn isolation(&self, _file: &ParsedFile, _line: u32) -> Option<String> {
        None
    }

    /// Components the language's own manifests declare (TypeScript's npm packages), for its files that no
    /// Bazel target claimed. They come before Bazel packages and folders.
    fn add_components(&self, _source: &SideSource, _layout: &mut ComponentLayout) {}
    /// The module a Bazel target of the language compiles into, from what sits in its package directory.
    fn target_module(&self, _source: &SideSource, _package_dir: &str) -> Option<String> {
        None
    }
    /// What an import names, for languages whose imports name files or packages rather than modules
    /// (TypeScript). None means the import names a module, as in Swift and Kotlin.
    fn resolve_import(&self, _source: &SideSource, _file: &str, _spec: &str) -> Option<ImportTarget> {
        None
    }
}

static SWIFT: swift::SwiftLanguage = swift::SwiftLanguage;
static KOTLIN: kotlin::KotlinLanguage = kotlin::KotlinLanguage;
static TYPESCRIPT: typescript::TypeScriptLanguage = typescript::TypeScriptLanguage;

/// The languages of phase 1 that are analyzed.
pub fn all() -> Vec<&'static dyn Language> {
    vec![&SWIFT, &KOTLIN, &TYPESCRIPT]
}

/// The language that parses `path`, if any.
pub fn of(path: &str) -> Option<&'static dyn Language> {
    all().into_iter().find(|l| l.is_source(path))
}

pub fn named(id: &str) -> Option<&'static dyn Language> {
    all().into_iter().find(|l| l.id() == id)
}

pub fn display_name(id: &str) -> String {
    named(id).map(|l| l.display_name().to_string()).unwrap_or_else(|| id.to_string())
}

/// Splits "swift:codable-shape" into the language and the flag; None when the flag has no known prefix.
pub fn split_flag(flag: &str) -> Option<(&'static dyn Language, &str)> {
    let (prefix, name) = flag.split_once(':')?;
    Some((named(prefix)?, name))
}

/// Languages that are compiled into the reviewed targets but not analyzed, by file extension.
pub fn gap_language(path: &str) -> Option<&'static str> {
    let ext = path.rsplit('.').next()?;
    match ext {
        "java" => Some("java"),
        "m" | "mm" => Some("objc"),
        _ => None,
    }
}

/// Conformers by explicit inheritance clauses: the default for languages with nominal conformance. Through the
/// index in the main report, by name only in the comparison report (CORE-003).
pub fn default_conformers(interface: &Pair, requirement: Option<&Pair>, builder: &Builder, use_: ConformanceUse) -> Vec<Conformer> {
    match builder.mode_of(&interface.any().parsed.language) {
        Mode::NameBased => named_conformers(interface, requirement, builder, use_),
        Mode::Index => indexed_conformers(interface, requirement, builder, use_),
        Mode::Preliminary | Mode::SyntaxOnly => Vec::new(),
    }
}

/// Conformers whose inheritance clause the index resolves to the interface's head declaration, with their
/// implementations of `requirement`: members of the conformer's type and of its resolved extensions.
pub fn indexed_conformers(interface: &Pair, requirement: Option<&Pair>, builder: &Builder, use_: ConformanceUse) -> Vec<Conformer> {
    let Some(ihead) = interface.head.as_ref() else { return Vec::new() };
    let hierarchy = &builder.hierarchy;
    let member = requirement.and_then(|r| r.head.as_ref()).map(|h| h.decl());
    if let (ConformanceUse::Check, Some(member)) = (use_, member) {
        let abstract_ = ihead.decl().kind == ItemKind::Class && member.modifiers.iter().any(|m| m == "abstract");
        // An existing default implementation in an extension of the interface covers every explicit conformer.
        let has_default = hierarchy.extensions_of(ihead).iter().any(|extension| {
            extension.parsed.decls.iter().any(|m| m.parent_index == Some(extension.index) && m.name == member.name)
        });
        if !abstract_ && has_default {
            return Vec::new();
        }
    }
    let mut result = Vec::new();
    for candidate in hierarchy.inheritors_of(ihead) {
        if use_ == ConformanceUse::Check {
            let component = &ihead.component;
            if candidate.component != *component && !builder.has_edge(Side::Head, &candidate.component, component) {
                continue;
            }
        }
        let mut implementations = Vec::new();
        if let Some(member) = member {
            for implementation in hierarchy.members_of(candidate) {
                let d = implementation.decl();
                let ok = d.name == member.name
                    && (d.kind == member.kind || kind_group(d.kind) == kind_group(member.kind))
                    && (use_ == ConformanceUse::Check || implementation.component == candidate.component);
                if ok {
                    implementations.push(implementation);
                }
            }
        }
        result.push(Conformer { declaration: candidate.clone(), implementations });
    }
    result
}

/// Conformers by the names in inheritance clauses: only for the comparison report.
fn named_conformers(interface: &Pair, requirement: Option<&Pair>, builder: &Builder, use_: ConformanceUse) -> Vec<Conformer> {
    let idecl = interface.any().decl();
    let name: String = match use_ {
        ConformanceUse::Check => idecl.qualified_name.clone(),
        // A whole-interface context uses its simple name, while a requirement context uses its enclosing
        // scope (which may be qualified).
        ConformanceUse::Context => match requirement {
            Some(r) => r.any().decl().scope.clone().unwrap_or_default(),
            None => idecl.name.clone(),
        },
    };
    let member = requirement.and_then(|r| r.head.as_ref()).map(|h| h.decl());
    if use_ == ConformanceUse::Check {
        if let Some(member) = member {
            let abstract_ = idecl.kind == ItemKind::Class && member.modifiers.iter().any(|m| m == "abstract");
            // An existing default implementation covers every explicit conformer.
            let has_default = builder.head_members.get(&format!("{name}|{}", member.name)).map(|list| {
                list.iter().any(|implementation| {
                    implementation.decl().parent_index.and_then(|p| implementation.parsed.decls.get(p)).map(|p| p.kind == ItemKind::Extension).unwrap_or(false)
                })
            });
            if !abstract_ && has_default == Some(true) {
                return Vec::new();
            }
        }
    }
    let mut result = Vec::new();
    for candidate in builder.inheritors.get(&name).map(Vec::as_slice).unwrap_or(&[]) {
        if use_ == ConformanceUse::Check {
            let component = &interface.any().component;
            if candidate.component != *component && !builder.has_edge(Side::Head, &candidate.component, component) {
                continue;
            }
        }
        let ty = candidate.decl().type_name().to_string();
        let mut implementations = Vec::new();
        if let Some(member) = member {
            for implementation in builder.head_members.get(&format!("{ty}|{}", member.name)).map(Vec::as_slice).unwrap_or(&[]) {
                let ok = match use_ {
                    ConformanceUse::Check => {
                        implementation.decl().kind == member.kind || kind_group(implementation.decl().kind) == kind_group(member.kind)
                    }
                    ConformanceUse::Context => implementation.component == candidate.component,
                };
                if ok {
                    implementations.push(implementation.clone());
                }
            }
        }
        result.push(Conformer { declaration: candidate.clone(), implementations });
    }
    result
}

/// The names a container conforms to or inherits from, without attributes.
pub fn inherited_names(d: &Declaration) -> impl Iterator<Item = &str> {
    d.inherited.iter().map(|s| conformance_name(s))
}
