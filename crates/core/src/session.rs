//! One review, from the two refs to the reports the UI shows.
//!
//! A session reads the two revisions from the object database and parses them, which is enough for a
//! preliminary report. Refining it needs Bazel: the session brings the app-owned workspaces to the two
//! revisions, asks Bazel for the build graph (components become targets), and builds each language's
//! index (links become exact). After each step it builds the report again from everything it has, so
//! the UI can replace what it shows. Notes and reviewed marks are keyed by review item and region ids,
//! which don't depend on the step.

use crate::analyze::components;
use crate::analyze::finish::AnalysisExtras;
use crate::analyze::{BuildOptions, Builder, Mode, SideData, SideSource};
use crate::bazel::graph::{SideGraph, WorkspaceGraph};
use crate::bazel::query::{load_graph, Scope};
use crate::bazel::workspace::{BazelEnv, Workspaces};
use crate::bazel::{self, discover_workspaces, workspace_of};
use crate::config::{Config, Glob};
use crate::git::{read_blob, Repo, Tree};
use crate::index::kotlin::KotlinIndexJob;
use crate::index::swift::SwiftIndexJob;
use crate::index::SideIndex;
use crate::lang::{self, Language};
use crate::model::*;
use crate::parse::cache::SyntaxCache;
use crate::parse::swift_helper::SwiftHelper;
use crate::parse::{kotlin, typescript, ParsedFile};
use crate::paths::is_under;
use crate::proc::{is_cancelled, timer, Cancel};
use anyhow::{anyhow, Result};
use rayon::prelude::*;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

fn default_true() -> bool {
    true
}

fn default_base() -> String {
    "main".to_string()
}

fn default_max_refs() -> usize {
    50
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewRequest {
    /// The repository, or any directory inside it.
    pub repo: PathBuf,
    #[serde(default = "default_base")]
    pub base: String,
    /// Default: the branch checked out in the repository.
    #[serde(default)]
    pub head: Option<String>,
    /// Compare against the merge-base of base and head (CORE-001). False compares against base itself.
    #[serde(default = "default_true")]
    pub use_merge_base: bool,
    /// Where `reviewmap` was run. The Bazel workspace around it is the one explicit targets belong to.
    #[serde(default)]
    pub cwd: Option<PathBuf>,
    /// Bazel targets that define the review scope, overriding reviewmap.yml.
    #[serde(default)]
    pub targets: Vec<String>,
    /// Extra Bazel arguments (a config), overriding reviewmap.yml.
    #[serde(default)]
    pub bazel_args: Vec<String>,
    /// Whether to build indexes. None follows reviewmap.yml, and is on when that doesn't say.
    #[serde(default)]
    pub index: Option<bool>,
    #[serde(default = "default_max_refs")]
    pub max_refs_per_edge: usize,
    /// The LLM pass to run on the final report. None: no LLM pass (the core never picks one by itself).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub llm: Option<crate::llm::LlmOptions>,
}

impl ReviewRequest {
    pub fn new(repo: impl Into<PathBuf>) -> ReviewRequest {
        ReviewRequest {
            repo: repo.into(),
            base: "main".to_string(),
            head: None,
            use_merge_base: true,
            cwd: None,
            targets: Vec::new(),
            bazel_args: Vec::new(),
            index: None,
            max_refs_per_edge: 50,
            llm: None,
        }
    }
}

/// The callback a session reports through. Worker threads call it too.
pub type Emit<'a> = &'a (dyn Fn(Event) + Sync);

/// What a session tells its caller while it works.
pub enum Event {
    /// What is happening now, for the progress line.
    Progress(String),
    /// A report that replaces the one shown.
    Report(Box<ChangeReport>),
}

pub struct Session {
    pub repo: Repo,
    pub info: RepoInfo,
    pub config: Config,
    request: ReviewRequest,
    base: Arc<SideSource>,
    head: Arc<SideSource>,
    /// Every Bazel workspace of either revision, repo-relative.
    workspaces: Vec<String>,
    /// The workspaces the change touches, which are the ones queried and indexed.
    in_scope: Vec<String>,
    primary: Option<String>,
    graphs: Option<(SideGraph, SideGraph)>,
    /// Each indexed language's references at base and head.
    indexes: BTreeMap<String, (SideIndex, SideIndex)>,
    /// Why a language is not indexed, once that is final.
    notes: BTreeMap<String, String>,
    /// Whether indexes are wanted at all. When they are not, every language is syntax-only from the start.
    index_enabled: bool,
    warnings: Vec<Warning>,
    workspace_infos: Vec<WorkspaceInfo>,
    stage: String,
}

impl Session {
    /// Reads and parses the two revisions. The session can build a preliminary report afterwards.
    pub fn open(request: ReviewRequest, cancel: &Cancel, emit: Emit) -> Result<Session> {
        let resolving = timer("open: resolve revisions");
        let repo = Repo::discover(&request.repo)?;
        let head_ref = request.head.clone().unwrap_or_else(|| repo.current_branch());
        let head_sha = repo.resolve(&head_ref)?;
        let base_ref_sha = repo.resolve(&request.base)?;
        // CORE-001: by default the base is the merge-base, which is what a pull request shows.
        let base_sha = if request.use_merge_base {
            repo.merge_base(base_ref_sha, head_sha)?
                .ok_or_else(|| anyhow!("{} and {head_ref} share no history, so there is no merge-base. Compare against the base itself instead.", request.base))?
        } else {
            base_ref_sha
        };
        let info = RepoInfo {
            root: repo.root().to_string_lossy().to_string(),
            base: request.base.clone(),
            head: head_ref,
            base_sha: base_sha.to_string(),
            head_sha: head_sha.to_string(),
            uses_merge_base: request.use_merge_base,
        };
        drop(resolving);
        emit(Event::Progress(format!("Reading {} and {}", &info.base_sha[..8], &info.head_sha[..8])));
        let reading = timer("read trees");
        let base_tree = Arc::new(repo.tree(base_sha)?);
        let head_tree = Arc::new(repo.tree(head_sha)?);
        drop(reading);
        cancel.check()?;

        // reviewmap.yml is read from the head commit's tree, not from the working tree (CORE-002).
        let config = match head_tree.get("reviewmap.yml") {
            Some(entry) => Config::parse(&String::from_utf8_lossy(&repo.blob(entry.oid)?)).map_err(|e| anyhow!("reviewmap.yml at {}: {e}", &info.head_sha[..8]))?,
            None => Config::default(),
        };

        let languages = lang::all();
        let excludes = config.exclude_matchers();
        let parsing = timer("parse both sides");
        let (base_files, head_files) = parse_sides(&repo, &base_tree, &head_tree, &languages, &excludes, cancel, emit)?;
        drop(parsing);
        let _scoping = timer("open: workspaces");
        let generated = |tree_files: &BTreeMap<String, Arc<ParsedFile>>| -> HashSet<String> {
            let mut matchers = config.generated_matchers();
            matchers.extend(languages.iter().flat_map(|l| l.generated_patterns().iter()).map(|p| Glob::new(p)));
            tree_files.iter().filter(|(p, f)| f.is_generated || matchers.iter().any(|g| g.matches(p))).map(|(p, _)| p.clone()).collect()
        };
        let base_generated = generated(&base_files);
        let head_generated = generated(&head_files);
        let base = Arc::new(SideSource::new(Side::Base, info.base_sha.clone(), base_tree.clone(), base_files, base_generated, repo.clone()));
        let head = Arc::new(SideSource::new(Side::Head, info.head_sha.clone(), head_tree.clone(), head_files, head_generated, repo.clone()));

        let workspaces: Vec<String> = discover_workspaces(&head_tree).into_iter().chain(discover_workspaces(&base_tree)).collect::<BTreeSet<_>>().into_iter().collect();
        // The workspaces the change touches: the innermost one around each changed source file.
        let mut in_scope: BTreeSet<String> = BTreeSet::new();
        let paths: BTreeSet<&String> = base_tree.keys().chain(head_tree.keys()).collect();
        for path in paths {
            if base_tree.get(path).map(|e| e.oid) == head_tree.get(path).map(|e| e.oid) || lang::of(path).is_none() {
                continue;
            }
            if let Some(w) = workspace_of(&workspaces, path) {
                in_scope.insert(w.to_string());
            }
        }
        // Explicit targets belong to the workspace around the directory the review was started from.
        let cwd_rel = request.cwd.as_ref().and_then(|c| std::fs::canonicalize(c).ok()).and_then(|c| c.strip_prefix(repo.root()).ok().map(|p| p.to_string_lossy().to_string()));
        let primary = cwd_rel
            .as_deref()
            .and_then(|c| workspace_of(&workspaces, &format!("{}{}", c, if c.is_empty() { "." } else { "/." })).map(str::to_string))
            .filter(|w| in_scope.contains(w) || in_scope.is_empty())
            .or_else(|| if in_scope.len() == 1 { in_scope.iter().next().cloned() } else { None })
            .or_else(|| in_scope.contains("").then(String::new))
            .or_else(|| in_scope.iter().next().cloned());
        if in_scope.is_empty() {
            if let Some(p) = &primary {
                in_scope.insert(p.clone());
            }
        }
        let index_enabled = request.index.or(config.index.as_ref().and_then(|i| i.enabled)).unwrap_or(true);
        Ok(Session {
            repo,
            info,
            config,
            request,
            base,
            head,
            workspaces,
            in_scope: in_scope.into_iter().collect(),
            primary,
            graphs: None,
            indexes: BTreeMap::new(),
            notes: BTreeMap::new(),
            index_enabled,
            warnings: Vec::new(),
            workspace_infos: Vec::new(),
            stage: "preliminary".to_string(),
        })
    }

    /// The languages with source files at either side.
    fn languages(&self) -> Vec<&'static dyn Language> {
        lang::all().into_iter().filter(|l| self.base.files.values().chain(self.head.files.values()).any(|f| f.language == l.id())).collect()
    }

    pub fn stage(&self) -> &str {
        &self.stage
    }

    /// The text of a file at one side, for the code views.
    pub fn read_source(&self, side: Side, file: &str) -> Option<String> {
        match side {
            Side::Base => self.base.text(file),
            Side::Head => self.head.text(file),
        }
    }

    /// The report from everything the session knows now. A language without an index shows only what syntax
    /// proves: preliminary while its index is still to come, syntax-only once it is known there won't be one
    /// (CORE-003).
    pub fn report(&self) -> ChangeReport {
        let mut modes: BTreeMap<String, Mode> = BTreeMap::new();
        for l in self.languages() {
            let mode = if self.indexes.contains_key(l.id()) {
                Mode::Index
            } else if !self.index_enabled || self.notes.contains_key(l.id()) {
                Mode::SyntaxOnly
            } else {
                Mode::Preliminary
            };
            modes.insert(l.id().to_string(), mode);
        }
        self.build(modes, "indexed")
    }

    /// The comparison report: the same revisions and components with every reference matched by name, as the
    /// prototype did without an index. It carries no index warnings, because no index was asked of it. It is
    /// the only report that matches by name (CORE-003), and its `analysis.variant` says so.
    pub fn name_based_report(&self) -> ChangeReport {
        let modes = self.languages().into_iter().map(|l| (l.id().to_string(), Mode::NameBased)).collect();
        self.build(modes, "name-based")
    }

    fn build(&self, modes: BTreeMap<String, Mode>, variant: &str) -> ChangeReport {
        let _timer = timer(format!("report build ({variant}, {} stage)", self.stage));
        let languages = self.languages();
        let all = lang::all();
        let layout = |source: &Arc<SideSource>, graph: Option<&SideGraph>| components::build(source, &all, &self.config, &self.workspaces, graph);
        let base = SideData::new(self.base.clone(), layout(&self.base, self.graphs.as_ref().map(|g| &g.0)));
        let head = SideData::new(self.head.clone(), layout(&self.head, self.graphs.as_ref().map(|g| &g.1)));
        let indexed = variant == "indexed";
        let options = BuildOptions { max_refs_per_edge: self.request.max_refs_per_edge, modes: modes.clone(), stage: self.stage.clone(), variant: variant.to_string() };
        let mut builder = Builder::new(&base, &head, if languages.is_empty() { all.clone() } else { languages.clone() }, options);
        let notes = self.final_notes();
        if indexed {
            for w in &self.warnings {
                builder.warnings.insert(w.clone());
            }
            for l in &languages {
                if let Some((b, h)) = self.indexes.get(l.id()) {
                    builder.add_index(*l, b, h);
                } else if let Some(note) = notes.get(l.id()) {
                    // CORE-003: a language that ends without an index shows only what syntax proves, and says why.
                    builder.warnings.insert(Warning::new(
                        "index-unavailable",
                        format!(
                            "{} has no index, so it shows only links that syntax proves, and the checks that need every reference (unused-api, orphaned, untested, conformers) did not run. The reason: {note}",
                            l.display_name()
                        ),
                    ));
                }
            }
        }
        builder.diff_external_deps();
        builder.match_review_items();
        builder.resolve_references();
        builder.add_contract_files();
        builder.add_target_settings();
        let extras = AnalysisExtras { workspaces: self.workspace_infos.clone(), notes: if indexed { notes } else { BTreeMap::new() } };
        builder.finish(self.info.clone(), &self.config, &extras)
    }

    /// Why each language that won't get an index has none: that indexes are turned off, or what failed.
    fn final_notes(&self) -> BTreeMap<String, String> {
        if !self.index_enabled {
            return self.languages().into_iter().map(|l| (l.id().to_string(), "indexes are turned off for this review".to_string())).collect();
        }
        self.notes.clone()
    }

    /// The scope of one workspace at one side: explicit targets, rules_xcodeproj's, or everything.
    fn scope(&self, workspace: &str, source: &SideSource) -> Scope {
        if self.primary.as_deref() == Some(workspace) {
            let explicit =
                if !self.request.targets.is_empty() { self.request.targets.clone() } else { self.config.index.as_ref().and_then(|i| i.targets.clone()).unwrap_or_default() };
            if !explicit.is_empty() {
                return Scope { targets: explicit, kind: "explicit".to_string() };
            }
        }
        for name in bazel::BUILD_FILES {
            if let Some(text) = source.text(&crate::paths::join(workspace, name)) {
                let targets = bazel::xcodeproj_targets(&text);
                if !targets.is_empty() {
                    return Scope { targets, kind: "xcodeproj".to_string() };
                }
                break;
            }
        }
        Scope { targets: vec!["//...".to_string()], kind: "all".to_string() }
    }

    fn bazel_args(&self) -> Vec<String> {
        if !self.request.bazel_args.is_empty() {
            self.request.bazel_args.clone()
        } else {
            self.config.index.as_ref().and_then(|i| i.bazel_args.clone()).unwrap_or_default()
        }
    }

    fn has_workspace(source: &SideSource, workspace: &str) -> bool {
        bazel::WORKSPACE_FILES.iter().any(|f| source.tree.contains_key(&crate::paths::join(workspace, f)))
    }

    /// Refines the report: the build graph, then each language's index. Emits a report after each step.
    /// A step that fails leaves a warning and the report as far as it got; only cancelling is an error.
    ///
    /// Swift and Kotlin are indexed in the Bazel workspaces the change touches. TypeScript is indexed in
    /// those that use rules_ts, and in Yarn Classic projects, which need no Bazel.
    pub fn refine(&mut self, cancel: &Cancel, emit: Emit) -> Result<()> {
        let languages: Vec<&'static str> = self.languages().iter().map(|l| l.id()).collect();
        let bazel_only: Vec<&'static str> = languages.iter().copied().filter(|l| *l != "typescript").collect();
        let finish = |session: &mut Session, emit: Emit| {
            session.stage = "complete".to_string();
            emit(Event::Report(Box::new(session.report())));
        };
        let bazel_tool = crate::tools::bazel();
        let mut trees: Option<Trees> = None;
        let mut scopes: BTreeMap<(Side, String), Scope> = BTreeMap::new();
        let args = self.bazel_args();
        if self.in_scope.is_empty() {
            // Nothing for Bazel to say: no workspace holds changed source.
            for l in &bazel_only {
                self.notes.entry(l.to_string()).or_insert_with(|| "the change touches no Bazel workspace, and phase 1 indexes Bazel projects only".to_string());
            }
        } else if let Some(bazel_tool) = bazel_tool.clone() {
            let t = self.trees(&mut trees, cancel, emit)?;
            let env = |side: Side, w: &str| BazelEnv::new(bazel_tool.clone(), t.spaces.workspace_dir(side, w), t.spaces.output_base(side, w), args.clone());
            let (head_source, base_source) = (self.head.clone(), self.base.clone());
            let source = move |side: Side| if side == Side::Head { head_source.clone() } else { base_source.clone() };

            // Step 1: the build graph.
            let mut graphs = (SideGraph::default(), SideGraph::default());
            for w in self.in_scope.clone() {
                let mut info = WorkspaceInfo { path: if w.is_empty() { ".".to_string() } else { w.clone() }, graph: "none".to_string(), ..Default::default() };
                for side in [Side::Head, Side::Base] {
                    let src = source(side);
                    if !Self::has_workspace(&src, &w) {
                        continue;
                    }
                    let scope = self.scope(&w, &src);
                    if side == Side::Head {
                        info.targets = scope.targets.clone();
                        info.scope = scope.kind.clone();
                    }
                    scopes.insert((side, w.clone()), scope.clone());
                    let at = if w.is_empty() { String::new() } else { format!(" of {w}") };
                    emit(Event::Progress(format!("Asking Bazel for the {} build graph{at}", side.name())));
                    let querying = timer(format!("graph {} workspace {w:?}", side.name()));
                    let loaded = load_graph(&env(side, &w), &w, &scope, cancel, &|m| emit(Event::Progress(format!("{m} ({})", side.name()))));
                    drop(querying);
                    match loaded {
                        Ok(graph) => {
                            if side == Side::Head {
                                info.graph = if graph.configured { "configured" } else { "unconfigured" }.to_string();
                            }
                            push_graph(if side == Side::Head { &mut graphs.1 } else { &mut graphs.0 }, graph);
                        }
                        Err(e) => {
                            if is_cancelled(&e) {
                                return Err(e);
                            }
                            self.warnings.push(Warning::new(
                                "bazel-graph-unavailable",
                                format!("Bazel could not report the {} build graph{at}, so its components are Bazel packages: {}", side.name(), first_lines(&e.to_string(), 3)),
                            ));
                        }
                    }
                }
                self.workspace_infos.push(info);
            }
            // A graph for one side only would cut the two sides into different components.
            let complete: BTreeSet<String> =
                graphs.1.workspaces.iter().map(|g| g.workspace.clone()).filter(|w| graphs.0.workspace(w).is_some() || !Self::has_workspace(&self.base, w)).collect();
            graphs.0.workspaces.retain(|g| complete.contains(&g.workspace));
            graphs.1.workspaces.retain(|g| complete.contains(&g.workspace));
            self.graphs = Some(graphs);
            self.stage = "graph".to_string();
            emit(Event::Report(Box::new(self.report())));
            cancel.check()?;

            // Step 2: each language's index, workspace by workspace and at both sides (see `index_workspaces`).
            // A language with no index at all is syntax-only at both sides, so they are resolved the same way.
            if self.index_enabled {
                let cache = crate::store::cache_root().join("index");
                let repo_key = crate::store::repo_key(self.repo.root());
                let bazel_units = self.bazel_units();
                if languages.contains(&"swift") {
                    let result = SwiftHelper::start().and_then(|mut helper| {
                        self.index_workspaces("swift", "Swift", &bazel_units, &source, cancel, |w, side, src, files| {
                            let scope = scopes.get(&(side, w.to_string())).ok_or_else(|| anyhow!("Bazel could not report its build graph"))?;
                            if scope.kind == "all" {
                                return Err(anyhow!(
                                    "no Bazel targets define its review scope. Set index.targets in reviewmap.yml, or start the review with --target //app:App, so that libraries are compiled in the application's configuration"
                                ));
                            }
                            let job = SwiftIndexJob {
                                env: &env(side, w),
                                side,
                                sha: &src.sha,
                                workspace: w,
                                targets: &scope.targets,
                                tree_dir: t.dir(side),
                                files,
                                cache_dir: cache.join("swift").join(&repo_key),
                            };
                            let result = crate::index::swift::load(&job, &mut helper, cancel, &|m| emit(Event::Progress(m)))?;
                            let mut index = SideIndex { refs: result.refs, warnings: Vec::new() };
                            if let Some(p) = result.partial {
                                index.warnings.push(Warning::new("index-partial", p));
                            }
                            Ok(index)
                        })
                    });
                    self.take_index("swift", result)?;
                    emit(Event::Report(Box::new(self.report())));
                }
                if languages.contains(&"kotlin") {
                    let result = self.index_workspaces("kotlin", "Kotlin", &bazel_units, &source, cancel, |w, side, src, files| {
                        if !bazel::uses_module(&|f| src.text(&crate::paths::join(w, f)), "rules_kotlin") {
                            return Err(anyhow!("it does not build Kotlin with rules_kotlin"));
                        }
                        let scope = scopes.get(&(side, w.to_string())).ok_or_else(|| anyhow!("Bazel could not report its build graph"))?;
                        let blobs: BTreeMap<String, String> = files.iter().filter_map(|p| src.tree.get(p).map(|e| (p.clone(), e.oid.to_string()))).collect();
                        let job = KotlinIndexJob {
                            env: &env(side, w),
                            side,
                            sha: &src.sha,
                            workspace: w,
                            targets: &scope.targets,
                            blobs: &blobs,
                            log_dir: cache.join("kotlin").join(&repo_key),
                        };
                        crate::index::kotlin::load(&job, cancel, &|m| emit(Event::Progress(m)))
                    });
                    self.take_index("kotlin", result)?;
                    if languages.contains(&"typescript") {
                        emit(Event::Report(Box::new(self.report())));
                    }
                }
            }
        } else {
            for l in &bazel_only {
                self.notes.insert(l.to_string(), "Bazel was not found (looked on the PATH and in the usual install locations; REVIEWMAP_BAZEL names another)".to_string());
            }
            self.warnings.push(Warning::new("bazel-unavailable", "Bazel was not found, so components are Bazel packages and not targets."));
        }

        if self.index_enabled && languages.contains(&"typescript") {
            let result = self.index_typescript(&mut trees, bazel_tool.as_ref(), &scopes, cancel, emit);
            self.take_index("typescript", result)?;
        }
        finish(self, emit);
        Ok(())
    }

    /// The app-owned base and head trees, brought to the two revisions the first time a step needs them.
    /// They are only changed here, between jobs, under the repository's lock.
    fn trees<'t>(&self, trees: &'t mut Option<Trees>, cancel: &Cancel, emit: Emit) -> Result<&'t Trees> {
        if trees.is_none() {
            emit(Event::Progress("Waiting for this repository's app-owned workspaces".to_string()));
            let locking = timer("workspace lock");
            let spaces = Workspaces::acquire(self.repo.root(), cancel)?;
            drop(locking);
            let progress = |m: String| emit(Event::Progress(m));
            let materializing = timer("materialize head tree");
            let head = spaces.materialize(&self.repo, Side::Head, &self.head.tree, &self.info.head_sha, cancel, &progress)?;
            drop(materializing);
            let materializing = timer("materialize base tree");
            let base = spaces.materialize(&self.repo, Side::Base, &self.base.tree, &self.info.base_sha, cancel, &progress)?;
            drop(materializing);
            *trees = Some(Trees { spaces, head, base });
        }
        Ok(trees.as_ref().expect("the trees were just made"))
    }

    /// The Bazel workspaces in scope, as the units Swift and Kotlin are indexed in.
    fn bazel_units(&self) -> Units<'static> {
        let workspaces = self.workspaces.clone();
        Units {
            dirs: self.in_scope.clone(),
            of: Box::new(move |path: &str| workspace_of(&workspaces, path).map(str::to_string)),
            exists: Box::new(|src: &SideSource, w: &str| Self::has_workspace(src, w)),
            name: Box::new(|w: &str| if w.is_empty() { "the root workspace".to_string() } else { w.to_string() }),
            none: "no Bazel workspace in the change has {language} files".to_string(),
        }
    }

    /// TypeScript's index, over the projects that hold its changed files: Bazel workspaces that use rules_ts,
    /// and package-manager roots outside them, of which phase 1 indexes Yarn Classic ones. A Yarn Berry, pnpm,
    /// or npm root is not indexed, and its files show only links that syntax proves, with a warning that says
    /// why (for Berry: that support comes later).
    fn index_typescript(&self, trees: &mut Option<Trees>, bazel_tool: Option<&PathBuf>, scopes: &BTreeMap<(Side, String), Scope>, cancel: &Cancel, emit: Emit) -> Result<(SideIndex, SideIndex)> {
        use crate::index::typescript::{load, unsupported, Setup, TypeScriptIndexJob};
        use crate::lang::typescript::project;
        let rules_ts = |src: &SideSource, w: &str| Self::has_workspace(src, w) && bazel::uses_module(&|f| src.text(&crate::paths::join(w, f)), "aspect_rules_ts");
        let bazel_ws: BTreeSet<String> = self.workspaces.iter().filter(|w| rules_ts(&self.head, w) || rules_ts(&self.base, w)).cloned().collect();
        let mut roots: BTreeSet<String> = BTreeSet::new();
        for src in [&self.head, &self.base] {
            for r in &project(src).roots {
                if !bazel_ws.iter().any(|w| is_under(&r.dir, w)) {
                    roots.insert(r.dir.clone());
                }
            }
        }
        let all: Vec<String> = bazel_ws.iter().chain(roots.iter()).cloned().collect();
        let unit_of = move |path: &str| -> Option<String> { all.iter().filter(|u| is_under(path, u)).max_by_key(|u| u.len()).cloned() };
        // The units that hold a changed TypeScript file.
        let mut dirs: BTreeSet<String> = BTreeSet::new();
        let paths: BTreeSet<&String> = self.base.files.keys().chain(self.head.files.keys()).collect();
        for path in paths {
            let language = self.head.files.get(path).or_else(|| self.base.files.get(path)).map(|f| f.language.as_str());
            if language != Some("typescript") || self.base.tree.get(path).map(|e| e.oid) == self.head.tree.get(path).map(|e| e.oid) {
                continue;
            }
            if let Some(u) = unit_of(path) {
                dirs.insert(u);
            }
        }
        let bazel_names = bazel_ws.clone();
        let units = Units {
            dirs: dirs.into_iter().collect(),
            of: Box::new(unit_of),
            exists: Box::new(move |src: &SideSource, u: &str| if bazel_ws.contains(u) { Self::has_workspace(src, u) } else { project(src).roots.iter().any(|r| r.dir == u) }),
            name: Box::new(move |u: &str| {
                let place = if u.is_empty() { "the repository root".to_string() } else { u.to_string() };
                if bazel_names.contains(u) { format!("the Bazel workspace {place}") } else { place }
            }),
            none: "the change's TypeScript files are in no Yarn Classic project and no Bazel workspace that uses rules_ts".to_string(),
        };
        let (head_source, base_source) = (self.head.clone(), self.base.clone());
        let source = move |side: Side| if side == Side::Head { head_source.clone() } else { base_source.clone() };
        let args = self.bazel_args();
        let log_dir = crate::store::cache_root().join("index").join("typescript").join("logs").join(crate::store::repo_key(self.repo.root()));
        self.index_workspaces("typescript", "TypeScript", &units, &source, cancel, |u, side, src, files| {
            let bazel_unit = rules_ts(src, u);
            if !bazel_unit {
                let p = project(src);
                let root = p.roots.iter().find(|r| r.dir == u).ok_or_else(|| anyhow!("it has no package.json at {}", side.name()))?;
                if let Some(why) = unsupported(&root.manager, &root.evidence) {
                    return Err(anyhow!(why));
                }
            }
            if bazel_unit && bazel_tool.is_none() {
                return Err(anyhow!("it builds TypeScript with rules_ts, and Bazel was not found (looked on the PATH and in the usual install locations; REVIEWMAP_BAZEL names another)"));
            }
            if crate::tools::node().is_none() {
                return Err(anyhow!(
                    "TypeScript indexing needs Node.js, which was not found (looked on the PATH, in the usual install locations, and in Volta, nvm, fnm, mise, and asdf; REVIEWMAP_NODE names another)"
                ));
            }
            let t = self.trees(trees, cancel, emit)?;
            let env;
            let default_targets = vec!["//...".to_string()];
            let setup = if bazel_unit {
                let bazel_tool = bazel_tool.expect("checked above");
                env = BazelEnv::new(bazel_tool.clone(), t.spaces.workspace_dir(side, u), t.spaces.output_base(side, u), args.clone());
                let targets = scopes.get(&(side, u.to_string())).filter(|s| s.kind != "all").map(|s| &s.targets).unwrap_or(&default_targets);
                Setup::Bazel { env: &env, targets }
            } else {
                let p = project(src);
                let root = p.roots.iter().find(|r| r.dir == u).expect("checked above");
                Setup::Yarn {
                    pin: root.yarn_pin.clone(),
                    has_lockfile: root.has_lockfile,
                    in_bazel_workspace: workspace_of(&self.workspaces, &crate::paths::join(u, "package.json")).is_some(),
                }
            };
            let job = TypeScriptIndexJob { side, sha: &src.sha, dir: u, tree_dir: t.dir(side), source: src, files: &files, setup, log_dir: log_dir.clone() };
            load(&job, cancel, &|m| emit(Event::Progress(m)))
        })
    }

    /// One language's index over a set of units: the Bazel workspaces in scope, or TypeScript's projects.
    /// `build` makes the index of one unit at one side, given that side's files of the language in the unit.
    ///
    /// A unit is indexed at every side it exists at, or not at all: its files that exist at both sides
    /// could not use an index of one side anyway. A unit that can't be indexed (it doesn't build the
    /// language with Bazel, it has no scope targets, its build failed, it is a Yarn Berry project) leaves
    /// its files syntax-only and says why in an `index-partial` warning (CORE-003); it doesn't take the other
    /// units' indexes with it. Only when no unit could be indexed is the language without an index.
    fn index_workspaces(
        &self,
        language: &str,
        display_name: &str,
        units: &Units,
        source: &dyn Fn(Side) -> Arc<SideSource>,
        cancel: &Cancel,
        mut build: impl FnMut(&str, Side, &SideSource, Vec<String>) -> Result<SideIndex>,
    ) -> Result<(SideIndex, SideIndex)> {
        let mut sides = (SideIndex::default(), SideIndex::default());
        let mut built = 0;
        let mut problems: Vec<(String, String)> = Vec::new();
        for w in &units.dirs {
            let name = (units.name)(w);
            let mut pair = (None, None);
            let mut problem = None;
            for side in [Side::Head, Side::Base] {
                let src = source(side);
                let files: Vec<String> = src.files.iter().filter(|(p, f)| f.language == language && (units.of)(p).as_deref() == Some(w.as_str())).map(|(p, _)| p.clone()).collect();
                if files.is_empty() || !(units.exists)(&src, w) {
                    continue;
                }
                let indexing = timer(format!("index {language} {} {w:?}", side.name()));
                let built_index = build(w, side, &src, files);
                drop(indexing);
                match built_index {
                    Ok(index) => *(if side == Side::Head { &mut pair.1 } else { &mut pair.0 }) = Some(index),
                    Err(e) => {
                        if is_cancelled(&e) {
                            return Err(e);
                        }
                        problem = Some(first_lines(&format!("{e:#}"), 8));
                        break;
                    }
                }
                cancel.check()?;
            }
            match (problem, pair) {
                (Some(reason), _) => problems.push((name, reason)),
                (None, (None, None)) => {}
                (None, (base, head)) => {
                    for (target, index) in [(&mut sides.0, base), (&mut sides.1, head)] {
                        let index = index.unwrap_or_default();
                        target.refs.extend(index.refs);
                        target.warnings.extend(index.warnings);
                    }
                    built += 1;
                }
            }
        }
        if built == 0 {
            return Err(match problems.as_slice() {
                [] => anyhow!("{}", units.none.replace("{language}", display_name)),
                [(name, reason)] => anyhow!("{name}: {reason}"),
                many => anyhow!("{}", many.iter().map(|(name, reason)| format!("{name}: {reason}")).collect::<Vec<_>>().join("\n")),
            });
        }
        for (name, reason) in problems {
            sides.1.warnings.push(Warning::new(
                "index-partial",
                format!("{display_name} files of {name} show only links that syntax proves, because its index could not be built: {reason}"),
            ));
        }
        Ok(sides)
    }

    /// Gives the session a language's index at base and head. `refine` builds them; the acceptance tests
    /// pass their own, standing in for the indexers.
    pub fn set_index(&mut self, language: &str, base: SideIndex, head: SideIndex) {
        self.notes.remove(language);
        self.indexes.insert(language.to_string(), (base, head));
    }

    /// Records a language's index, or why it has none. Cancelling is passed on.
    fn take_index(&mut self, language: &str, result: Result<(SideIndex, SideIndex)>) -> Result<()> {
        match result {
            Ok((base, head)) => self.set_index(language, base, head),
            Err(e) => {
                if is_cancelled(&e) {
                    return Err(e);
                }
                self.notes.insert(language.to_string(), first_lines(&format!("{e:#}"), 8));
            }
        }
        Ok(())
    }

    /// After cancelling: the languages that were still waiting for an index end syntax-only, with the warning
    /// that says so, and the report is final.
    pub fn finish_cancelled(&mut self) -> ChangeReport {
        for l in self.languages() {
            if !self.indexes.contains_key(l.id()) {
                self.notes.entry(l.id().to_string()).or_insert_with(|| "indexing was cancelled".to_string());
            }
        }
        self.stage = "complete".to_string();
        self.report()
    }
}

/// The app-owned base and head trees of a review, held under the repository's lock.
struct Trees {
    spaces: Workspaces,
    head: PathBuf,
    base: PathBuf,
}

impl Trees {
    fn dir(&self, side: Side) -> &Path {
        if side == Side::Head {
            &self.head
        } else {
            &self.base
        }
    }
}

type UnitOf<'u> = Box<dyn Fn(&str) -> Option<String> + 'u>;
type UnitExists<'u> = Box<dyn Fn(&SideSource, &str) -> bool + 'u>;
type UnitName<'u> = Box<dyn Fn(&str) -> String + 'u>;

/// The places a language is indexed in, one by one.
struct Units<'u> {
    /// Repo-relative directories.
    dirs: Vec<String>,
    /// The unit a file belongs to.
    of: UnitOf<'u>,
    /// Whether a unit exists at a side.
    exists: UnitExists<'u>,
    /// How warnings name a unit.
    name: UnitName<'u>,
    /// Why there is no index when no unit has the language's files; `{language}` is its name.
    none: String,
}

fn push_graph(side: &mut SideGraph, graph: WorkspaceGraph) {
    side.workspaces.retain(|g| g.workspace != graph.workspace);
    side.workspaces.push(graph);
}

fn first_lines(text: &str, n: usize) -> String {
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    let mut out = lines[..lines.len().min(n)].join("\n");
    if lines.len() > n {
        out.push_str("\n…");
    }
    out
}

/// Opens a session, emits the preliminary report, and refines it. Cancelling during refinement still
/// returns the session, with its report made final. When the request asks for the LLM pass, it runs on the
/// final report and emits one more report with its annotations; cancelling it leaves the final report as it
/// was (CORE-004).
pub fn run(request: ReviewRequest, cancel: &Cancel, emit: Emit) -> Result<Session> {
    let mut session = Session::open(request, cancel, emit)?;
    // The latest report, for the LLM pass.
    let last: Mutex<Option<ChangeReport>> = Mutex::new(None);
    let wants_llm = session.request.llm.is_some();
    let forward = |event: Event| {
        if let (true, Event::Report(report)) = (wants_llm, &event) {
            *last.lock().unwrap() = Some((**report).clone());
        }
        emit(event)
    };
    let emit: Emit = &forward;
    emit(Event::Report(Box::new(session.report())));
    let mut cancelled = false;
    match session.refine(cancel, emit) {
        Ok(()) => {}
        Err(e) if is_cancelled(&e) => {
            cancelled = true;
            emit(Event::Report(Box::new(session.finish_cancelled())));
        }
        Err(e) => {
            // Refinement is best effort: what failed is said in a warning, and the report stays usable.
            session.warnings.push(Warning::new("analysis-incomplete", format!("The analysis stopped early: {}", first_lines(&format!("{e:#}"), 6))));
            for l in session.languages() {
                session.notes.entry(l.id().to_string()).or_insert_with(|| "the analysis stopped early".to_string());
            }
            session.stage = "complete".to_string();
            emit(Event::Report(Box::new(session.report())));
        }
    }
    let report = last.lock().unwrap().take();
    if let (Some(options), Some(report), false) = (session.request.llm.clone(), report, cancelled) {
        if report.analysis.stage == "complete" && !cancel.is_cancelled() {
            let progress = |m: String| emit(Event::Progress(m));
            let annotator = crate::llm::Annotator { options: &options };
            match annotator.run(&report, &session, cancel, &progress) {
                Ok(annotated) => emit(Event::Report(Box::new(annotated))),
                // Cancelled: the final report stays as it is.
                Err(e) if is_cancelled(&e) => {}
                Err(e) => return Err(e),
            }
        }
    }
    Ok(session)
}

// MARK: Parsing

type Parsed = BTreeMap<String, Arc<ParsedFile>>;

/// Parses the source files of both revisions. A blob is parsed once however many paths and sides hold it,
/// and not at all when the syntax cache has it. A TypeScript blob is parsed once per grammar: the same
/// content parses differently as `.ts` and as `.tsx`.
fn parse_sides(
    repo: &Repo,
    base: &Tree,
    head: &Tree,
    languages: &[&'static dyn Language],
    excludes: &[Glob],
    cancel: &Cancel,
    emit: Emit,
) -> Result<(Parsed, Parsed)> {
    // (blob id, grammar) -> a path that holds it. The grammar is the language id, or "tsx".
    type Key = (gix::ObjectId, &'static str);
    let mut blobs: BTreeMap<Key, String> = BTreeMap::new();
    let wanted = |tree: &Tree| -> Vec<(String, Key)> {
        tree.iter()
            .filter(|(_, e)| matches!(e.mode, crate::git::EntryMode::File | crate::git::EntryMode::Executable))
            .filter_map(|(p, e)| {
                let language = languages.iter().find(|l| l.is_source(p))?;
                let grammar = if language.id() == "typescript" && typescript::is_tsx(p) { "tsx" } else { language.id() };
                (!excludes.iter().any(|g| g.matches(p))).then(|| (p.clone(), (e.oid, grammar)))
            })
            .collect()
    };
    let base_list = wanted(base);
    let head_list = wanted(head);
    for (path, key) in base_list.iter().chain(head_list.iter()) {
        blobs.entry(*key).or_insert(path.clone());
    }
    let mut parsed: HashMap<Key, Arc<ParsedFile>> = HashMap::new();

    // Kotlin and TypeScript: tree-sitter, in parallel.
    type Parse = fn(&str) -> ParsedFile;
    let tree_sitter: [(&str, &str, SyntaxCache, Parse); 3] = [
        ("kotlin", "Kotlin", SyntaxCache::new("kotlin", kotlin::PARSER_VERSION), kotlin::parse),
        ("typescript", "TypeScript", SyntaxCache::new("typescript", typescript::PARSER_VERSION), |s| typescript::parse(s, false)),
        ("tsx", "TSX", SyntaxCache::new("tsx", typescript::PARSER_VERSION), |s| typescript::parse(s, true)),
    ];
    for (grammar, name, cache, parse) in &tree_sitter {
        let keys: Vec<Key> = blobs.keys().filter(|k| k.1 == *grammar).copied().collect();
        if keys.is_empty() {
            continue;
        }
        emit(Event::Progress(format!("Parsing {} {name} files", keys.len())));
        let results: Vec<(Key, Arc<ParsedFile>)> = keys
            .par_iter()
            .map_init(
                || repo.local(),
                |local, key| {
                    let id = key.0.to_string();
                    if let Some(hit) = cache.get(&id) {
                        return (*key, Arc::new(hit));
                    }
                    let text = read_blob(local, key.0).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
                    let file = parse(&text);
                    cache.put(&id, &file);
                    (*key, Arc::new(file))
                },
            )
            .collect();
        parsed.extend(results);
        cancel.check()?;
    }

    // Swift: the helper, in batches, for the blobs the cache doesn't have.
    let swift_blobs: Vec<(gix::ObjectId, String)> = blobs.iter().filter(|(k, _)| k.1 == "swift").map(|(k, p)| (k.0, p.clone())).collect();
    if !swift_blobs.is_empty() {
        // The cache key needs the helper's version, so the helper starts even when everything is cached.
        let mut helper = SwiftHelper::start().map_err(|e| anyhow!("Swift files can't be parsed: {e}"))?;
        let swift_cache = SyntaxCache::new("swift", &helper.version);
        let cached: Vec<(gix::ObjectId, Option<ParsedFile>)> = swift_blobs.par_iter().map(|(oid, _)| (*oid, swift_cache.get(&oid.to_string()))).collect();
        let mut missing: Vec<(gix::ObjectId, String)> = Vec::new();
        let paths: HashMap<gix::ObjectId, &String> = swift_blobs.iter().map(|(o, p)| (*o, p)).collect();
        for (oid, hit) in cached {
            match hit {
                Some(file) => {
                    parsed.insert((oid, "swift"), Arc::new(file));
                }
                None => missing.push((oid, paths[&oid].clone())),
            }
        }
        if !missing.is_empty() {
            emit(Event::Progress(format!("Parsing {} Swift files", missing.len())));
            let local = repo.local();
            let results: Mutex<Vec<(String, ParsedFile)>> = Mutex::new(Vec::new());
            let mut done = 0;
            for chunk in missing.chunks(200) {
                cancel.check()?;
                let batch: Vec<(String, String, String)> = chunk
                    .iter()
                    .map(|(oid, path)| (oid.to_string(), path.clone(), read_blob(&local, *oid).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default()))
                    .collect();
                helper.parse(&batch, |key, file| results.lock().unwrap().push((key, file)))?;
                done += chunk.len();
                if missing.len() > 400 {
                    emit(Event::Progress(format!("Parsing Swift files: {done} of {}", missing.len())));
                }
            }
            let by_key: HashMap<String, gix::ObjectId> = missing.iter().map(|(o, _)| (o.to_string(), *o)).collect();
            for (key, file) in results.into_inner().unwrap() {
                swift_cache.put(&key, &file);
                if let Some(oid) = by_key.get(&key) {
                    parsed.insert((*oid, "swift"), Arc::new(file));
                }
            }
        }
    }

    let collect = |list: Vec<(String, Key)>| -> Parsed { list.into_iter().filter_map(|(path, key)| parsed.get(&key).map(|f| (path, f.clone()))).collect() };
    Ok((collect(base_list), collect(head_list)))
}

/// Whether a path is inside any of the given workspaces.
pub fn in_workspaces(workspaces: &[String], path: &str) -> bool {
    workspaces.iter().any(|w| is_under(path, w))
}

/// The directory a review's notes and marks are kept in, for a repository root.
pub fn review_state_dir(root: &Path) -> PathBuf {
    crate::store::data_root().join("reviews").join(crate::store::repo_key(root))
}
