//! The change report: the contract between the analyzer and the review UI.
//!
//! It follows the prototype's `Sources/ReviewMapCore/Model.swift`, with the changes of version 5:
//! components can be Bazel targets or packages, a review item's id starts with its file instead of its
//! component (so the id survives the move from preliminary to refined components), and `analysis`
//! says how far the analysis got and how each language's references were resolved.

use serde::{Deserialize, Serialize};

pub const REPORT_VERSION: u32 = 5;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ChangeReport {
    pub version: u32,
    pub analyzer: AnalyzerInfo,
    pub repo: RepoInfo,
    pub analysis: AnalysisInfo,
    pub components: Vec<Component>,
    pub edges: Vec<Edge>,
    pub external_deps: Vec<ExternalDepChange>,
    pub review_items: Vec<ReviewItem>,
    pub regions: Vec<Region>,
    pub warnings: Vec<Warning>,
    /// Structural review: the deterministic checks' findings, then the LLM's.
    pub findings: Vec<Finding>,
    /// Set when the LLM pass ran (see `crate::llm`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub llm: Option<LlmRun>,
}

/// How the LLM pass went.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LlmRun {
    /// "claude" or "codex".
    pub tool: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The file name of the command run instead of the tool, when one was given.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    pub prompt_version: String,
    /// Annotation batches, cached components included.
    pub batches: usize,
    /// Components whose annotations all came from the cache.
    pub cached: usize,
    /// Batches whose reply was rejected; their regions keep the deterministic scores (CORE-004).
    pub failed: usize,
    /// Whether the head commit's REVIEW.md was in the prompts.
    pub review_notes: bool,
    /// The structural review: "ok", "cached", "rejected", or "skipped".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review: Option<String>,
    /// Where the change's description came from: "pr" or "commits".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// The LLM's one-line summary of a component or a review item.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct LlmSummary {
    pub summary: String,
}

/// The LLM's view of a region: review and removed regions get a risk, context regions keep and rank.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct RegionLlm {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub risk: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keep: Option<bool>,
    /// Kept context regions of a review item, from 1 (most needed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rank: Option<u32>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AnalyzerInfo {
    pub version: String,
    /// "index" when an index resolved at least one language, "name-based" when every language was matched by
    /// name (the comparison report), "preliminary" while a language still waits for its index, and "syntax"
    /// when no language has an index and none is still to come: only links that syntax proves are shown.
    pub resolution: String,
    /// Ids of the languages with source files in the change ("swift").
    pub languages: Vec<String>,
}

/// How far the analysis got. The UI shows a preliminary report first and replaces it as the build graph
/// and the indexes arrive.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct AnalysisInfo {
    /// "preliminary" (syntax only), "graph" (components and declared dependencies come from Bazel), or
    /// "complete" (every language was indexed or ended syntax-only, because its index failed, was cancelled,
    /// or is turned off).
    pub stage: String,
    /// "indexed" for the main report, "name-based" for the comparison report that matches every reference by name.
    pub variant: String,
    pub languages: Vec<LanguageCoverage>,
    /// Source files of languages that are compiled but not analyzed (Java, Objective-C), by language.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub gaps: Vec<CoverageGap>,
    /// The Bazel workspaces the components came from, repo-relative ("." for the root).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub workspaces: Vec<WorkspaceInfo>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct LanguageCoverage {
    pub id: String,
    /// "preliminary" (the index is still to come), "syntax" (final without an index: only links that syntax
    /// proves), "index", or "name-based" (only in the comparison report).
    pub resolution: String,
    /// Files of the language at head that are neither tests nor generated, and how many of them the index covers.
    pub files: usize,
    pub indexed_files: usize,
    /// Why the language is not indexed, when it is not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// The checks that did not run for the language because reference coverage is incomplete
    /// ("unused-api", "orphaned", "untested", "conformers"). Empty while the report is preliminary.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub held_back: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct CoverageGap {
    /// "java" or "objc".
    pub language: String,
    /// Files of the language that the change touches.
    pub changed_files: usize,
    /// Files of the language at head.
    pub files: usize,
    /// Up to five changed files.
    pub sample: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceInfo {
    pub path: String,
    /// The targets that define the review scope.
    pub targets: Vec<String>,
    /// "explicit" (reviewmap.yml or the launch), "xcodeproj" (rules_xcodeproj's top_level_targets), or "all" (//...).
    pub scope: String,
    /// "configured" (cquery), "unconfigured" (query, when cquery failed), or "none" (no graph: components are packages).
    pub graph: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RepoInfo {
    pub root: String,
    pub base: String,
    pub head: String,
    pub base_sha: String,
    pub head_sha: String,
    /// True when baseSha is the merge-base of base and head (pull request semantics).
    pub uses_merge_base: bool,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub enum ComponentKind {
    /// A Bazel target that owns source files.
    BazelTarget,
    /// A Bazel package, while the build graph is not known.
    BazelPackage,
    Folder,
    External,
    /// An npm package: a package.json with a name, outside the Bazel targets.
    NpmPackage,
    /// A directory with a tsconfig.json that no package covers.
    Tsconfig,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Component {
    pub id: String,
    pub name: String,
    pub kind: ComponentKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layer: Option<String>,
    /// Module the component's code compiles into, if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub module: Option<String>,
    /// For components split out of a large target: the target component they came from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    pub is_test: bool,
    pub paths: Vec<String>,
    /// "added" / "removed" when the component exists on one side only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    pub changed_review_items: usize,
    pub interface_changes: usize,
    /// 0..1, drives emphasis on the map.
    pub change_score: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub llm: Option<LlmSummary>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum EdgeStatus {
    Added,
    Removed,
    Changed,
    Unchanged,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Edge {
    pub from: String,
    pub to: String,
    pub status: EdgeStatus,
    /// Referenced symbols that appear only at head / only at base.
    pub symbols_added: Vec<String>,
    pub symbols_removed: Vec<String>,
    /// The references that create this edge (capped; differing symbols first).
    pub refs: Vec<Ref>,
    pub ref_count: usize,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Base,
    Head,
}

impl Side {
    pub fn name(self) -> &'static str {
        match self {
            Side::Base => "base",
            Side::Head => "head",
        }
    }
    pub fn other(self) -> Side {
        match self {
            Side::Base => Side::Head,
            Side::Head => Side::Base,
        }
    }
    pub const BOTH: [Side; 2] = [Side::Base, Side::Head];
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub struct Ref {
    pub file: String,
    /// 0 means the reference comes from a BUILD file rather than a source line.
    pub line: u32,
    pub symbol: String,
    pub side: Side,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum ItemKind {
    Struct,
    Class,
    Enum,
    Actor,
    Protocol,
    Extension,
    Func,
    Init,
    Var,
    Case,
    Typealias,
    /// Non-code contract file: Info.plist, entitlements, privacy manifest, Core Data model, Android manifest.
    File,
    /// Target-level build settings.
    Target,
}

impl ItemKind {
    pub fn raw(self) -> &'static str {
        match self {
            ItemKind::Struct => "struct",
            ItemKind::Class => "class",
            ItemKind::Enum => "enum",
            ItemKind::Actor => "actor",
            ItemKind::Protocol => "protocol",
            ItemKind::Extension => "extension",
            ItemKind::Func => "func",
            ItemKind::Init => "init",
            ItemKind::Var => "var",
            ItemKind::Case => "case",
            ItemKind::Typealias => "typealias",
            ItemKind::File => "file",
            ItemKind::Target => "target",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum ChangeKind {
    Added,
    Removed,
    Signature,
    Body,
    Modifiers,
    Cosmetic,
}

impl ChangeKind {
    pub fn raw(self) -> &'static str {
        match self {
            ChangeKind::Added => "added",
            ChangeKind::Removed => "removed",
            ChangeKind::Signature => "signature",
            ChangeKind::Body => "body",
            ChangeKind::Modifiers => "modifiers",
            ChangeKind::Cosmetic => "cosmetic",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Location {
    pub file: String,
    pub start_line: u32,
    pub end_line: u32,
    pub side: Side,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
pub struct Signature {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
}

/// A reference from code in another component to a review item (or from a review item to another component).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub component: String,
    /// Qualified name of the declaration that contains the reference (or the referenced declaration for dependsOn).
    pub symbol: String,
    pub file: String,
    pub line: u32,
    /// usedBy: the isolation the reference runs in, when its declaration or an enclosing type says.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isolation: Option<String>,
    /// usedBy: "base" for a use that only exists at base; missing at head.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub side: Option<Side>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReviewItem {
    /// "<file>::<qualified name>", with "#n" for the nth declaration of that name in the file's pairing.
    pub id: String,
    pub component: String,
    pub kind: ItemKind,
    pub qualified_name: String,
    /// Id of the enclosing declaration, if any. It may be an unchanged declaration, which is not a review item.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    pub is_interface: bool,
    pub change: ChangeKind,
    /// Every aspect that changed, most significant first.
    pub changes: Vec<ChangeKind>,
    pub signature: Signature,
    /// Contract flags, each prefixed with its language's id ("swift:mainactor-added").
    pub contract_flags: Vec<String>,
    /// "test", "generated".
    pub tags: Vec<String>,
    pub location: Location,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_location: Option<Location>,
    /// Declarations in other components that reference this review item.
    pub used_by: Vec<Usage>,
    /// Declarations in other components that this review item references.
    pub depends_on: Vec<Usage>,
    /// Added review items: existing declarations with similar names, which the new code may duplicate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub similar: Option<Vec<Usage>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub llm: Option<LlmSummary>,
}

/// A line range the reviewer should read. `review` regions are changed head lines, `removed` regions are
/// deleted base lines, and `context` regions are unchanged code that helps to understand the review
/// regions they support.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Region {
    /// "<review item id>/r<n>" for review and removed regions, "<review item id>/c<n>" for context.
    pub id: String,
    pub review_item: String,
    /// "review", "removed", or "context".
    pub kind: String,
    pub file: String,
    pub start_line: u32,
    pub end_line: u32,
    pub side: Side,
    /// 0..1, deterministic. Context regions are 0.
    pub risk: f64,
    /// Why the region is risky, most significant first. For context regions: the declaration shown.
    pub reasons: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supports: Option<Vec<String>>,
    /// Context: "definition", "caller", "conformer", "override", or "state".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub component: Option<String>,
    /// Context: the lines that matter. Missing means all of them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lines: Option<Vec<u32>>,
    /// Removed regions inside a changed review item: the head line the removed code followed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub llm: Option<RegionLlm>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct ExternalDepChange {
    pub name: String,
    /// added | removed | bumped
    pub change: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Warning {
    pub kind: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
}

impl Warning {
    pub fn new(kind: &str, message: impl Into<String>) -> Warning {
        Warning { kind: kind.to_string(), message: message.into(), file: None, line: None }
    }
    pub fn at(kind: &str, message: impl Into<String>, file: &str, line: u32) -> Warning {
        Warning { kind: kind.to_string(), message: message.into(), file: Some(file.to_string()), line: Some(line) }
    }
}

/// Something the structural review found, anchored to the parts of the map it is about.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Finding {
    /// "<check>:<n>", stable within one change report.
    pub id: String,
    /// "check" for the deterministic checks, "llm" for the LLM's structural review.
    pub source: String,
    /// Checks: "cycle", "layering", "new-external", "unused-api", "orphaned", "conformers", "untested".
    /// LLM: "intent", "placement", "missing", "duplicate", "complexity".
    pub kind: String,
    /// "high", "medium", or "low".
    pub severity: String,
    pub message: String,
    pub evidence: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggestion: Option<String>,
    /// Where it shows on the map; the first anchor is the main one.
    pub anchors: Vec<Anchor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub location: Option<Location>,
}

/// A component, an edge (from and to), or a review item.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Hash, Default)]
#[serde(rename_all = "camelCase")]
pub struct Anchor {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub component: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_item: Option<String>,
}

impl Anchor {
    pub fn component(id: &str) -> Anchor {
        Anchor { component: Some(id.to_string()), ..Default::default() }
    }
    pub fn edge(from: &str, to: &str) -> Anchor {
        Anchor { from: Some(from.to_string()), to: Some(to.to_string()), ..Default::default() }
    }
    pub fn review_item(id: &str) -> Anchor {
        Anchor { review_item: Some(id.to_string()), ..Default::default() }
    }
}
