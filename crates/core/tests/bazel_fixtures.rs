//! Index builds from start to end, on two small Bazel workspaces: `tests/fixtures/swift-bazel` (rules_swift)
//! and the prototype's `kotlin-bazel-indexed` (rules_kotlin). Each has the case name matching gets wrong.
//!
//! These tests start Bazel, so they are the slow ones. Each returns early, saying why, when a tool it needs
//! is missing (Bazel; the Swift helper and libIndexStore; a JDK), and all of them when
//! `REVIEWMAP_SKIP_BAZEL_TESTS` is set. The first run fetches the rules and scip-java, so it needs the
//! network once. The app's home for these tests is kept under Cargo's target directory, and the fixture
//! repositories are made at fixed paths in it, so Bazel's output bases are warm on later runs; the indexes
//! themselves are removed before every run, so the indexers always run.

mod common;

use common::*;
use reviewmap_core::model::{ChangeReport, EdgeStatus};
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

/// One Bazel test at a time: they share the home, and each stops the Bazel servers it started when it ends.
static BAZEL: Mutex<()> = Mutex::new(());

struct Bazel<'a> {
    home: &'static Path,
    _guard: MutexGuard<'a, ()>,
}

impl Drop for Bazel<'_> {
    fn drop(&mut self) {
        reviewmap_core::bazel::workspace::shutdown_all();
    }
}

fn bazel() -> Option<Bazel<'static>> {
    if std::env::var_os("REVIEWMAP_SKIP_BAZEL_TESTS").is_some() {
        eprintln!("skipped: REVIEWMAP_SKIP_BAZEL_TESTS is set");
        return None;
    }
    if reviewmap_core::tools::bazel().is_none() {
        eprintln!("skipped: Bazel is not installed");
        return None;
    }
    let guard = BAZEL.lock().unwrap_or_else(|e| e.into_inner());
    let home = home(Some("reviewmap-test-home"));
    Some(Bazel { home, _guard: guard })
}

/// Every file under a directory, `.git` included, with its size and modification time (CORE-002).
fn snapshot(root: &Path) -> std::collections::BTreeMap<String, String> {
    let mut out = std::collections::BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let path = entry.path();
            let meta = std::fs::symlink_metadata(&path).unwrap();
            let name = path.strip_prefix(root).unwrap().to_string_lossy().to_string();
            if meta.is_dir() {
                out.insert(name, "directory".to_string());
                stack.push(path);
            } else {
                out.insert(name, format!("{} {:?}", meta.len(), meta.modified().unwrap()));
            }
        }
    }
    out
}

fn used_by(report: &ChangeReport, name: &str) -> Vec<String> {
    let mut symbols: Vec<String> = review_item(report, name).used_by.iter().map(|u| u.symbol.clone()).collect();
    symbols.sort();
    symbols
}

fn stages(reports: &[ChangeReport]) -> Vec<&str> {
    let mut stages: Vec<&str> = reports.iter().map(|r| r.analysis.stage.as_str()).collect();
    stages.dedup();
    stages
}

/// A common member name (`load()` on Store and Cache) and a type declared in two modules (`Config` in
/// Storage and Settings, used module-qualified): the cases of the prototype's IndexTests.
#[test]
fn swift_index_through_bazel() {
    let Some(bazel) = bazel() else { return };
    if !swift_helper() {
        return;
    }
    if reviewmap_core::tools::lib_index_store().is_none() {
        eprintln!("skipped: no libIndexStore next to the Swift toolchain");
        return;
    }
    let repo = fixture_repo_at(&own_fixture("swift-bazel"), &bazel.home.join("repos/swift-bazel"));
    let _ = std::fs::remove_dir_all(bazel.home.join("cache/index/swift"));
    let before = snapshot(&repo.path());

    // The scope comes from the fixture's reviewmap.yml: index.targets is //App:App.
    let (session, reports, progress) = run(request(&repo));
    let report = reports.last().expect("a report");
    assert_eq!(stages(&reports), ["preliminary", "graph", "complete"]);
    assert_eq!(report.analyzer.resolution, "index", "{:?}", report.warnings);
    assert!(!report.warnings.iter().any(|w| w.kind.starts_with("index-")), "{:?}", report.warnings);
    let coverage = report.analysis.languages.iter().find(|l| l.id == "swift").expect("Swift's coverage");
    assert_eq!((coverage.resolution.as_str(), coverage.files, coverage.indexed_files), ("index", 6, 6));
    assert!(progress.iter().any(|m| m.starts_with("Building the Swift index of head")), "{progress:?}");

    // Components are the targets, from the configured graph.
    let workspace = &report.analysis.workspaces[0];
    assert_eq!((workspace.scope.as_str(), workspace.graph.as_str()), ("explicit", "configured"));
    assert!(report.components.iter().any(|c| c.id == "//Sources/Feed:Feed" && c.module.as_deref() == Some("Feed")), "{:?}", report.components);

    // Feed.cached() calls Cache.load(); only name matching counts it as a use of Store.load().
    assert_eq!(used_by(report, "Store.load()"), ["Feed.items()"]);
    let load = review_item(report, "Store.load()");
    let callers: Vec<&str> =
        report.regions.iter().filter(|r| r.review_item == load.id && r.relation.as_deref() == Some("caller")).map(|r| r.reasons[0].as_str()).collect();
    assert_eq!(callers, ["Feed.items()"]);

    // Feed.limit() uses Storage.Config, new at head; the other Config (Settings) is used at both sides.
    let edge = |report: &'_ ChangeReport, to: &str| report.edges.iter().find(|e| e.from == "//Sources/Feed:Feed" && e.to == to).cloned().expect("the dependency");
    let storage = edge(report, "//Sources/Storage:Storage");
    assert_eq!(storage.status, EdgeStatus::Changed);
    assert_eq!(storage.symbols_added, ["Config"]);
    assert_eq!(edge(report, "//Sources/Settings:Settings").status, EdgeStatus::Unchanged);
    let limit = review_item(report, "Feed.limit()");
    assert!(limit.depends_on.iter().any(|d| d.component == "//Sources/Storage:Storage" && d.symbol == "Config.limit"), "{:?}", limit.depends_on);
    assert!(!limit.depends_on.iter().any(|d| d.component == "//Sources/Settings:Settings"), "{:?}", limit.depends_on);
    let definitions: Vec<_> = report.regions.iter().filter(|r| r.review_item == limit.id && r.relation.as_deref() == Some("definition")).collect();
    assert!(definitions.iter().any(|r| r.reasons[0] == "Config" && r.file == "Sources/Storage/Config.swift"), "{definitions:?}");
    assert!(!definitions.iter().any(|r| r.file.starts_with("Sources/Settings")), "{definitions:?}");

    // The comparison report of the same review: every reference matched by name, and no index warning.
    let named = session.name_based_report();
    assert_eq!(named.analyzer.resolution, "name-based");
    assert_eq!(named.analysis.variant, "name-based");
    assert_eq!(used_by(&named, "Store.load()"), ["Feed.cached()", "Feed.items()"]);
    assert_eq!(edge(&named, "//Sources/Storage:Storage").status, EdgeStatus::Unchanged, "name matching doesn't see the module-qualified use");
    assert!(!named.warnings.iter().any(|w| w.kind.starts_with("index-")), "{:?}", named.warnings);

    // CORE-002: the builds ran in the app's own copies.
    assert_eq!(snapshot(&repo.path()), before, "nothing in the reviewed repository changed");

    // Another review of the same commits reads the kept index and builds nothing.
    let (_, again, progress) = run(request(&repo));
    assert!(progress.iter().any(|m| m.starts_with("Swift index for head") && m.ends_with("cached")), "{progress:?}");
    assert!(!progress.iter().any(|m| m.starts_with("Building the Swift index")), "{progress:?}");
    let again = again.last().unwrap();
    assert_eq!(again.edges, report.edges);
    assert_eq!(again.review_items, report.review_items);
}

/// `load()` is a method of both Store and Cache, in two targets; the app only calls Store's.
///
/// The rules_kotlin workspace sits in `android/`, as in a repository with a workspace per platform. The
/// root is a Bazel workspace too, without rules_kotlin, and the change touches a Kotlin file in it: that
/// workspace can't be indexed, which must not cost `android/` its index.
#[test]
fn kotlin_index_through_bazel() {
    let Some(bazel) = bazel() else { return };
    if reviewmap_core::tools::java().is_none() {
        eprintln!("skipped: no JDK (java on the PATH, or JAVA_HOME)");
        return;
    }
    let repo = nested_fixture_repo_at(
        &prototype_fixture("kotlin-bazel-indexed"),
        &bazel.home.join("repos/kotlin-bazel-indexed"),
        "android",
        &[
            ("MODULE.bazel", "module(name = \"root\")\n", "module(name = \"root\")\n"),
            ("BUILD.bazel", "", ""),
            ("scripts/Report.kt", "package scripts\n\nfun report(): String = \"base\"\n", "package scripts\n\nfun report(): String = \"head\"\n"),
        ],
    );
    let _ = std::fs::remove_dir_all(bazel.home.join("cache/index/kotlin"));
    let before = snapshot(&repo.path());

    let (session, reports, _) = run(request(&repo));
    let report = reports.last().expect("a report");
    if report.warnings.iter().any(|w| w.kind == "index-unavailable" && w.message.contains("scip-java")) {
        eprintln!("skipped: scip-java could not be downloaded: {:?}", report.warnings);
        return;
    }
    assert_eq!(stages(&reports), ["preliminary", "graph", "complete"]);
    assert_eq!(report.analyzer.resolution, "index", "{:?}", report.warnings);

    // No scope targets: every target of the workspace, and components are the targets, named with their workspace.
    let workspace = report.analysis.workspaces.iter().find(|w| w.path == "android").expect("the android workspace");
    assert_eq!((workspace.scope.as_str(), workspace.targets.as_slice()), ("all", ["//...".to_string()].as_slice()));
    for id in ["android//app:app", "android//store:store", "android//cache:cache"] {
        assert!(report.components.iter().any(|c| c.id == id), "no component {id}: {:?}", report.components.iter().map(|c| &c.id).collect::<Vec<_>>());
    }

    assert_eq!(used_by(report, "Store.load()"), ["start()"]);
    assert_eq!(used_by(report, "Cache.load()"), Vec::<String>::new(), "the app never calls Cache.load()");
    let named = session.name_based_report();
    assert!(!used_by(&named, "Cache.load()").is_empty(), "name matching can't tell the two load() methods apart");

    // CORE-003: the root workspace's Kotlin file shows only links that syntax proves, and the warnings say so
    // and why. Since a caller could sit in it, the checks that claim "no callers" don't run for Kotlin.
    let index_warnings: Vec<_> = report.warnings.iter().filter(|w| w.kind.starts_with("index-")).collect();
    assert!(index_warnings.iter().all(|w| w.kind == "index-partial" && w.message.contains("Kotlin")), "{index_warnings:?}");
    assert!(index_warnings.iter().any(|w| w.message.contains("the root workspace") && w.message.contains("rules_kotlin")), "{index_warnings:?}");
    assert!(index_warnings.iter().any(|w| w.message.contains("scripts/Report.kt")), "the uncovered file is listed: {index_warnings:?}");
    assert!(!index_warnings.iter().any(|w| w.message.contains("matched by name")), "{index_warnings:?}");
    let coverage = report.analysis.languages.iter().find(|l| l.id == "kotlin").expect("Kotlin's coverage");
    assert_eq!((coverage.resolution.as_str(), coverage.files, coverage.indexed_files), ("index", 4, 3));
    assert!(coverage.held_back.contains(&"unused-api".to_string()) && coverage.held_back.contains(&"orphaned".to_string()), "{coverage:?}");
    assert!(report.warnings.iter().any(|w| w.kind == "checks-held-back" && w.message.contains("Kotlin")), "{:?}", report.warnings);
    assert!(!report.findings.iter().any(|f| f.kind == "unused-api" || f.kind == "orphaned" || f.kind == "untested"), "{:?}", report.findings);

    assert_eq!(snapshot(&repo.path()), before, "nothing in the reviewed repository changed");
}

/// Needs no tools: when Bazel can't be found, the review ends syntax-only and says why (CORE-003).
#[test]
fn without_bazel_the_review_stays_syntax_only() {
    // The lock keeps the tests that do start Bazel from seeing the override.
    let _guard = BAZEL.lock().unwrap_or_else(|e| e.into_inner());
    home(Some("reviewmap-test-home"));
    let repo = fixture_repo(&prototype_fixture("kotlin-bazel-indexed"));
    std::env::set_var("REVIEWMAP_BAZEL", "reviewmap-no-such-bazel");
    let report = analyze(request(&repo));
    std::env::remove_var("REVIEWMAP_BAZEL");
    assert_eq!(report.analysis.stage, "complete");
    assert_eq!(report.analyzer.resolution, "syntax");
    assert!(report.analysis.languages.iter().all(|l| l.resolution == "syntax"), "{:?}", report.analysis.languages);
    assert!(report.warnings.iter().any(|w| w.kind == "index-unavailable" && w.message.contains("Kotlin") && w.message.contains("Bazel was not found")), "{:?}", report.warnings);
    // Name matching would link app to cache through `load()`; syntax doesn't.
    assert!(report.review_items.iter().all(|i| i.used_by.is_empty()), "{:?}", report.review_items);
    assert!(report.warnings.iter().any(|w| w.kind == "bazel-unavailable"), "{:?}", report.warnings);
}
