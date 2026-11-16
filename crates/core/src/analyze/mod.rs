//! The language-neutral analyzer: it matches the declarations of two revisions, resolves references,
//! and builds components, edges, review items, regions, and findings into a change report. It is a port
//! of the prototype's `Analyzer.swift`, `Regions.swift`, and `Checks.swift`, with three changes: content
//! comes from the object database instead of exported trees, components come from Bazel, and each
//! language's references are resolved in one of three modes (see `Mode`).

pub mod checks;
pub mod components;
pub mod finish;
pub mod matching;
pub mod references;
pub mod regions;
pub mod settings;
pub mod supertypes;

use crate::git::{Repo, Tree};
use crate::index::IndexedRef;
use crate::lang::Language;
use crate::model::*;
use crate::parse::{Declaration, ParsedFile};
use components::ComponentLayout;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::{Arc, Mutex};

/// How one language's references are resolved in a report.
///
/// CORE-003: the main report never matches references by name. Only the comparison report the user asks
/// for uses `NameBased`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// While the index is still to come: only links that syntax proves (imports that name one declaration or
    /// module, and the build graph), and no conclusions that need complete reference coverage.
    Preliminary,
    /// The language ends without an index (it could not be built, indexing was cancelled, or indexes are
    /// off). It shows what `Preliminary` shows, and the report carries an `index-unavailable` warning.
    SyntaxOnly,
    /// References are matched by name, as the prototype did without an index. Only the comparison report.
    NameBased,
    /// References come from the language's index. Files the index doesn't cover at both sides show only
    /// links that syntax proves and are listed in an `index-partial` warning.
    Index,
}

impl Mode {
    /// Whether the language shows only what syntax proves: still waiting, or final without an index.
    pub fn is_syntax_only(self) -> bool {
        matches!(self, Mode::Preliminary | Mode::SyntaxOnly)
    }
}

/// One revision's content: its tree, its parsed source files, and its text. It doesn't depend on how the
/// tree is cut into components, so the same source serves the preliminary and the refined reports.
pub struct SideSource {
    pub side: Side,
    pub sha: String,
    pub tree: Arc<Tree>,
    /// Parsed source files of the supported languages, minus excluded paths.
    pub files: BTreeMap<String, Arc<ParsedFile>>,
    /// Paths tagged "generated": by pattern, or because the file says so.
    pub generated: HashSet<String>,
    repo: Repo,
    texts: Mutex<HashMap<String, Option<Arc<Vec<String>>>>>,
    /// What languages derive from the whole revision once (TypeScript's projects), by key.
    memo: Mutex<HashMap<&'static str, Arc<dyn std::any::Any + Send + Sync>>>,
}

impl SideSource {
    pub fn new(side: Side, sha: String, tree: Arc<Tree>, files: BTreeMap<String, Arc<ParsedFile>>, generated: HashSet<String>, repo: Repo) -> SideSource {
        SideSource { side, sha, tree, files, generated, repo, texts: Mutex::new(HashMap::new()), memo: Mutex::new(HashMap::new()) }
    }

    /// A value derived from this revision, made once by `make` and kept for the session.
    pub fn memo<T: std::any::Any + Send + Sync>(&self, key: &'static str, make: impl FnOnce() -> T) -> Arc<T> {
        if let Some(hit) = self.memo.lock().unwrap().get(key).cloned() {
            if let Ok(value) = hit.downcast::<T>() {
                return value;
            }
        }
        let value = Arc::new(make());
        self.memo.lock().unwrap().insert(key, value.clone());
        value
    }

    /// The bytes of a file at this revision.
    pub fn bytes(&self, path: &str) -> Option<Vec<u8>> {
        let entry = self.tree.get(path)?;
        self.repo.blob(entry.oid).ok()
    }

    /// The lines of a file at this revision, split at "\n" as the prototype did.
    pub fn lines(&self, path: &str) -> Option<Arc<Vec<String>>> {
        if let Some(hit) = self.texts.lock().unwrap().get(path) {
            return hit.clone();
        }
        let lines = self.bytes(path).map(|b| Arc::new(String::from_utf8_lossy(&b).split('\n').map(str::to_string).collect::<Vec<_>>()));
        self.texts.lock().unwrap().insert(path.to_string(), lines.clone());
        lines
    }

    pub fn text(&self, path: &str) -> Option<String> {
        self.bytes(path).map(|b| String::from_utf8_lossy(&b).into_owned())
    }

    /// Paths of the tree under a directory key: the path itself, or files inside it.
    pub fn has_path(&self, key: &str) -> bool {
        self.tree.contains_key(key) || self.tree.range(format!("{key}/")..).next().map(|(p, _)| p.starts_with(&format!("{key}/"))).unwrap_or(false)
    }
}

/// One revision cut into components.
pub struct SideData {
    pub source: Arc<SideSource>,
    pub layout: ComponentLayout,
    /// Top-level declared name -> components that declare it.
    pub decl_table: HashMap<String, BTreeSet<String>>,
}

impl SideData {
    pub fn new(source: Arc<SideSource>, layout: ComponentLayout) -> SideData {
        let mut decl_table: HashMap<String, BTreeSet<String>> = HashMap::new();
        for (path, file) in &source.files {
            let Some(comp) = layout.file_component.get(path) else { continue };
            for d in &file.decls {
                if d.is_top_level() && d.kind != ItemKind::Extension {
                    decl_table.entry(d.name.clone()).or_default().insert(comp.clone());
                }
            }
        }
        SideData { source, layout, decl_table }
    }

    pub fn side(&self) -> Side {
        self.source.side
    }

    pub fn files(&self) -> &BTreeMap<String, Arc<ParsedFile>> {
        &self.source.files
    }

    pub fn is_test_component(&self, id: &str) -> bool {
        self.layout.components.get(id).map(|c| c.is_test).unwrap_or(false)
    }
}

/// A declaration located at one side.
#[derive(Clone)]
pub struct Located {
    pub parsed: Arc<ParsedFile>,
    pub file: Arc<str>,
    pub index: usize,
    pub component: Arc<str>,
}

impl Located {
    pub fn decl(&self) -> &Declaration {
        &self.parsed.decls[self.index]
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DeclKey {
    pub side: Side,
    pub file: Arc<str>,
    pub index: usize,
}

impl DeclKey {
    pub fn new(side: Side, file: &str, index: usize) -> DeclKey {
        DeclKey { side, file: Arc::from(file), index }
    }
    pub fn of(side: Side, l: &Located) -> DeclKey {
        DeclKey { side, file: l.file.clone(), index: l.index }
    }
}

#[derive(Clone)]
pub struct Pair {
    pub base: Option<Located>,
    pub head: Option<Located>,
    pub id: String,
    pub changes: Vec<ChangeKind>,
    pub flags: Vec<String>,
}

impl Pair {
    pub fn any(&self) -> &Located {
        self.head.as_ref().or(self.base.as_ref()).expect("a pair has a base or a head")
    }
    pub fn at(&self, side: Side) -> Option<&Located> {
        match side {
            Side::Base => self.base.as_ref(),
            Side::Head => self.head.as_ref(),
        }
    }
    /// The side its review item is located at: head when it exists there.
    pub fn side(&self) -> Side {
        if self.head.is_some() {
            Side::Head
        } else {
            Side::Base
        }
    }
    pub fn is_changed(&self) -> bool {
        !self.changes.is_empty() && self.changes != [ChangeKind::Cosmetic]
    }
}

pub struct BuildOptions {
    /// Max references kept per edge in the output.
    pub max_refs_per_edge: usize,
    /// How each language's references are resolved, by language id.
    pub modes: BTreeMap<String, Mode>,
    /// "preliminary", "graph", or "complete".
    pub stage: String,
    /// "indexed" or "name-based".
    pub variant: String,
}

/// (side, from, to) -> refs.
pub type EdgeRefs = BTreeMap<String, BTreeMap<String, Vec<Ref>>>;

/// One line of a build settings review item that a changed setting is written on.
#[derive(Clone, Debug, PartialEq)]
pub struct SettingSpot {
    /// The flags of the settings on the line, with the language prefix.
    pub flags: Vec<String>,
    pub side: Side,
    pub line: u32,
    /// For a setting removed from a file that still sets others: the last head line before where it was.
    pub anchor: Option<u32>,
}

pub struct Builder<'a> {
    pub base: &'a SideData,
    pub head: &'a SideData,
    pub languages: Vec<&'static dyn Language>,
    pub options: BuildOptions,
    /// Head containers by their explicit inherited names, in source order. Name matching, so only the
    /// comparison report fills it (CORE-003); the main report uses `hierarchy`.
    pub inheritors: HashMap<String, Vec<Located>>,
    /// "Type|member" -> head declarations, in source order, across every file and component. Name matching,
    /// so only the comparison report fills it, like `inheritors`.
    pub head_members: HashMap<String, Vec<Located>>,
    /// Supertypes and extensions of head containers as the index resolves them, for indexed languages. Filled
    /// by `resolve_references`, once the indexes are added.
    pub hierarchy: supertypes::Hierarchy,

    pub pairs: Vec<Pair>,
    pub pair_of: HashMap<DeclKey, usize>,
    pub file_review_items: Vec<ReviewItem>,
    /// Build settings review item id -> where each of its changed settings is written, for its regions.
    pub setting_spots: HashMap<String, Vec<SettingSpot>>,
    pub warnings: BTreeSet<Warning>,
    edge_refs: [EdgeRefs; 2],
    /// pair index -> usages
    pub used_by: HashMap<usize, BTreeSet<Usage>>,
    pub depends_on: HashMap<usize, BTreeSet<Usage>>,
    /// id -> name
    pub external_components: BTreeMap<String, String>,
    pub external_deps: Vec<ExternalDepChange>,
    /// Package identities pinned on either side.
    pub pinned_packages: BTreeSet<String>,
    /// Exact references per side, for the files that are resolved through an index.
    index: [BTreeMap<String, Vec<IndexedRef>>; 2],
    /// Index mode: every head reference to a declaration, same component included (for caller context).
    pub index_callers: HashMap<usize, Vec<Usage>>,
    /// Ids of the languages whose references came from an index.
    pub indexed_languages: BTreeSet<String>,
    /// Per-language coverage, for the report's `analysis` section.
    pub coverage: BTreeMap<String, LanguageCoverage>,
    /// For each indexed language, whether its index covers what the checks that claim "no callers" need.
    pub check_coverage: BTreeMap<String, CheckCoverage>,
}

/// Whether a language's index covers, at head, every file that could hold a reference a check relies on
/// (CORE-003). Missing coverage must not become evidence of no callers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CheckCoverage {
    /// Every non-test file of the language, generated ones included: for `unused-api` and `orphaned`.
    pub callers: bool,
    /// Every test file of the language: for `untested`.
    pub tests: bool,
}

fn side_index(s: Side) -> usize {
    match s {
        Side::Base => 0,
        Side::Head => 1,
    }
}

impl<'a> Builder<'a> {
    pub fn new(base: &'a SideData, head: &'a SideData, languages: Vec<&'static dyn Language>, options: BuildOptions) -> Builder<'a> {
        let mut inheritors: HashMap<String, Vec<Located>> = HashMap::new();
        let mut head_members: HashMap<String, Vec<Located>> = HashMap::new();
        let by_name = options.modes.values().any(|m| *m == Mode::NameBased);
        for (path, file) in head.files().iter().filter(|_| by_name) {
            let Some(component) = head.layout.file_component.get(path) else { continue };
            let file_key: Arc<str> = Arc::from(path.as_str());
            let comp_key: Arc<str> = Arc::from(component.as_str());
            for (i, decl) in file.decls.iter().enumerate() {
                let located = Located { parsed: file.clone(), file: file_key.clone(), index: i, component: comp_key.clone() };
                if decl.is_container() {
                    for name in &decl.inherited {
                        inheritors.entry(conformance_name(name).to_string()).or_default().push(located.clone());
                    }
                }
                if let Some(scope) = &decl.scope {
                    head_members.entry(format!("{scope}|{}", decl.name)).or_default().push(located);
                }
            }
        }
        let mut warnings = BTreeSet::new();
        for w in base.layout.warnings.iter().chain(head.layout.warnings.iter()) {
            warnings.insert(w.clone());
        }
        Builder {
            base,
            head,
            languages,
            options,
            inheritors,
            head_members,
            hierarchy: supertypes::Hierarchy::default(),
            pairs: Vec::new(),
            pair_of: HashMap::new(),
            file_review_items: Vec::new(),
            setting_spots: HashMap::new(),
            warnings,
            edge_refs: [EdgeRefs::new(), EdgeRefs::new()],
            used_by: HashMap::new(),
            depends_on: HashMap::new(),
            external_components: BTreeMap::new(),
            external_deps: Vec::new(),
            pinned_packages: BTreeSet::new(),
            index: [BTreeMap::new(), BTreeMap::new()],
            index_callers: HashMap::new(),
            indexed_languages: BTreeSet::new(),
            coverage: BTreeMap::new(),
            check_coverage: BTreeMap::new(),
        }
    }

    pub fn side(&self, s: Side) -> &'a SideData {
        match s {
            Side::Base => self.base,
            Side::Head => self.head,
        }
    }

    /// The language of a parsed source file.
    pub fn language_of(&self, file: &str) -> &'static dyn Language {
        self.languages.iter().copied().find(|l| l.is_source(file)).unwrap_or(self.languages[0])
    }

    pub fn mode_of(&self, language: &str) -> Mode {
        self.options.modes.get(language).copied().unwrap_or(Mode::Preliminary)
    }

    /// Whether a language shows only what syntax proves (see `Mode::is_syntax_only`).
    pub fn is_syntax_only(&self, language: &str) -> bool {
        self.mode_of(language).is_syntax_only()
    }

    pub fn edge_refs(&self, s: Side) -> &EdgeRefs {
        &self.edge_refs[side_index(s)]
    }

    pub fn has_edge(&self, s: Side, from: &str, to: &str) -> bool {
        self.edge_refs(s).get(from).map(|m| m.contains_key(to)).unwrap_or(false)
    }

    pub fn add_ref(&mut self, s: Side, from: &str, to: &str, r: Ref) {
        if from == to {
            return;
        }
        self.edge_refs[side_index(s)].entry(from.to_string()).or_default().entry(to.to_string()).or_default().push(r);
    }

    /// The index references of a file, when the file is resolved through an index at this side.
    pub fn index_refs(&self, s: Side, file: &str) -> Option<&Vec<IndexedRef>> {
        self.index[side_index(s)].get(file)
    }

    pub fn index_covers(&self, s: Side, file: &str) -> bool {
        self.index[side_index(s)].contains_key(file)
    }

    pub fn index_of(&self, s: Side) -> &BTreeMap<String, Vec<IndexedRef>> {
        &self.index[side_index(s)]
    }

    pub(crate) fn index_mut(&mut self, s: Side) -> &mut BTreeMap<String, Vec<IndexedRef>> {
        &mut self.index[side_index(s)]
    }

    pub fn decl_at_index(&self, s: Side, file: &str, index: usize) -> Option<&'a Declaration> {
        self.side(s).files().get(file).and_then(|f| f.decls.get(index))
    }

    pub fn parent_pair(&self, l: &Located, s: Side) -> Option<usize> {
        let pi = l.decl().parent_index?;
        self.pair_of.get(&DeclKey { side: s, file: l.file.clone(), index: pi }).copied()
    }

    pub fn parent_decl<'l>(&self, l: &'l Located) -> Option<&'l Declaration> {
        l.decl().parent_index.and_then(|pi| l.parsed.decls.get(pi))
    }

    /// The declaration whose name sits at `line` of `file`: the innermost one around it, preferring one whose
    /// name matches the index's symbol name.
    pub fn decl_at(&self, s: Side, file: &str, line: u32, name: &str) -> Option<(usize, &'a Declaration)> {
        let parsed = self.side(s).files().get(file)?;
        let base = name.split('(').next().unwrap_or(name);
        let mut best: Option<(usize, &Declaration)> = None;
        let mut best_named: Option<(usize, &Declaration)> = None;
        for (i, d) in parsed.decls.iter().enumerate() {
            if d.start_line > line || line > d.end_line {
                continue;
            }
            let span = d.end_line - d.start_line;
            if best.map(|(_, b)| span <= b.end_line - b.start_line).unwrap_or(true) {
                best = Some((i, d));
            }
            if d.name == base && best_named.map(|(_, b)| span <= b.end_line - b.start_line).unwrap_or(true) {
                best_named = Some((i, d));
            }
        }
        best_named.or(best)
    }

    /// The top-level declaration that contains a declaration (itself when it is top level).
    pub fn top_level_decl(&self, s: Side, file: &str, index: usize) -> Option<&'a Declaration> {
        let parsed = self.side(s).files().get(file)?;
        let mut cur = index;
        while let Some(p) = parsed.decls.get(cur)?.parent_index {
            cur = p;
        }
        parsed.decls.get(cur)
    }

    pub fn located(&self, s: Side, file: &str, index: usize) -> Option<Located> {
        let data = self.side(s);
        let parsed = data.files().get(file)?;
        let component = data.layout.file_component.get(file)?;
        Some(Located { parsed: parsed.clone(), file: Arc::from(file), index, component: Arc::from(component.as_str()) })
    }
}

/// "@MainActor P" -> "P".
pub fn conformance_name(s: &str) -> &str {
    s.split(' ').filter(|p| !p.is_empty()).last().unwrap_or(s)
}

pub fn kind_group(k: ItemKind) -> &'static str {
    match k {
        ItemKind::Struct | ItemKind::Class | ItemKind::Enum | ItemKind::Actor => "type",
        ItemKind::Func | ItemKind::Init => "callable",
        other => other.raw(),
    }
}
