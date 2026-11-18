//! Index builds from start to end, on small Bazel workspaces: `tests/fixtures/swift-bazel` (rules_swift),
//! the prototype's `kotlin-bazel-indexed` (rules_kotlin), and `tests/fixtures/ts-bazel` (rules_ts with
//! rules_js). Each has the case name matching gets wrong.
//!
//! These tests start Bazel, so they are the slow ones. Each returns early, saying why, when a tool it needs
//! is missing (Bazel; the Swift helper and libIndexStore; a JDK; Node.js), and all of them when
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
    // Under `bazel test`, TEST_TMPDIR moves the nested Bazel's output user root, and with it the repository
    // cache, into this run's temporary directory, which is gone after the run. The kept output bases link
    // their external repositories into that cache, so every run downloaded the JDKs and the Kotlin compiler
    // again. Without it, the nested Bazel uses the user's own repository cache, as it does in the app.
    std::env::remove_var("TEST_TMPDIR");
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

    // CORE-003: Storage and Settings each declare a protocol Source. The compiler's index resolves the
    // inheritance clauses, so only LocalSource conforms to Storage's, whose requirement head changes.
    let fetch = report.review_items.iter().find(|i| i.qualified_name == "Source.fetch()" && i.location.file == "Sources/Storage/Config.swift").expect("the changed requirement");
    let conformers = findings(report, "conformers");
    assert!(conformers.len() == 1 && conformers[0].evidence.iter().any(|e| e.contains("LocalSource.fetch")), "{:?}", report.findings);
    assert!(!conformers[0].evidence.iter().any(|e| e.contains("ThemeSource")), "{:?}", conformers[0].evidence);
    let context: Vec<(&str, u32)> =
        report.regions.iter().filter(|r| r.review_item == fetch.id && r.relation.as_deref() == Some("conformer")).map(|r| (r.file.as_str(), r.start_line)).collect();
    assert_eq!(context, [("Sources/Feed/Feed.swift", 31)]);

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

/// The prototype fixture's `store/Store.kt` and `cache/Cache.kt` (base and head, by `change`), each with an
/// interface `Source` and an open class `Base` added: two pairs of supertypes with the same names. Head gives
/// store's `Source.fetch()` a default body and changes the body of store's `Base.name()`.
fn kotlin_supertypes(module: &str, change: &str, head: bool) -> String {
    let fetch = if head && module == "store" { "fun fetch(): Int = 0" } else { "fun fetch(): Int" };
    let name = if head && module == "store" { "\"store base\"".to_string() } else { format!("\"{module}\"") };
    let class = if module == "store" { "Store" } else { "Cache" };
    let own = if module == "cache" {
        "\nclass CacheSource : Base(), Source {\n    override fun fetch(): Int = 2\n    override fun name(): String = \"cache source\"\n}\n"
    } else {
        ""
    };
    format!(
        "package demo.{module}\n\nclass {class} {{\n    fun load(key: String): String {{\n        return \"{module}{change}\" + key\n    }}\n}}\n\ninterface Source {{\n    {fetch}\n}}\n\nopen class Base {{\n    open fun name(): String = {name}\n}}\n{own}"
    )
}

/// The fixture's `app/Main.kt` with a subclass of store's Base that implements store's Source, at lines 16 to 19.
const KOTLIN_MAIN: &str = "package demo.app\n\nimport demo.cache.Cache\nimport demo.store.Base\nimport demo.store.Source\nimport demo.store.Store\n\nvar warm: Cache? = null\n\nfun start() {\n    val s = Store()\n    println(s.load(\"a\") + (warm != null))\n}\n\nfun main() = start()\nclass LocalSource : Base(), Source {\n    override fun fetch(): Int = 1\n    override fun name(): String = \"local\"\n}\n";

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
            ("android/store/Store.kt", &kotlin_supertypes("store", ":", false), &kotlin_supertypes("store", "/", true)),
            ("android/cache/Cache.kt", &kotlin_supertypes("cache", ":", false), &kotlin_supertypes("cache", "/", true)),
            ("android/app/Main.kt", KOTLIN_MAIN, KOTLIN_MAIN),
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

    // CORE-003: store and cache each declare Source and Base. scip-java resolves the supertype list of
    // LocalSource (`Base()` names Base's constructor) to store's, so it alone is conformer and override context
    // of store's changes; CacheSource, of cache's Source and Base, is neither.
    let context = |name: &str, relation: &str| -> Vec<(String, u32)> {
        let item = report.review_items.iter().find(|i| i.qualified_name == name && i.location.file == "android/store/Store.kt").expect("the changed declaration");
        report.regions.iter().filter(|r| r.review_item == item.id && r.relation.as_deref() == Some(relation)).map(|r| (r.file.clone(), r.start_line)).collect()
    };
    assert_eq!(context("Source.fetch()", "conformer"), [("android/app/Main.kt".to_string(), 17)], "{:?}", report.regions);
    assert_eq!(context("Base.name()", "override"), [("android/app/Main.kt".to_string(), 18)], "{:?}", report.regions);

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

/// `load()` is a method of both Store and Cache in `//packages/lib`; the app only calls Store's. The app
/// imports the library by its package name, through the `node_modules` rules_js links, and one of its files
/// imports code that only a genrule makes, which the index can't see from the source tree.
#[test]
fn typescript_index_through_bazel() {
    let Some(bazel) = bazel() else { return };
    if reviewmap_core::tools::node().is_none() {
        eprintln!("skipped: Node.js was not found");
        return;
    }
    let repo = fixture_repo_at(&own_fixture("ts-bazel"), &bazel.home.join("repos/ts-bazel"));
    let _ = std::fs::remove_dir_all(bazel.home.join("cache/index/typescript"));
    let before = snapshot(&repo.path());

    let (session, reports, progress) = run(request(&repo));
    let report = reports.last().expect("a report");
    assert_eq!(stages(&reports), ["preliminary", "graph", "complete"]);
    assert_eq!(report.analyzer.resolution, "index", "{:?}", report.warnings);
    assert!(progress.iter().any(|m| m.starts_with("Building head") && m.contains("for the TypeScript index")), "{progress:?}");
    assert!(!progress.iter().any(|m| m.starts_with("Installing")), "nothing is installed for a Bazel workspace: {progress:?}");
    // Bazel builds what scip-typescript reads, not the scope (//...): the npm links the scope depends on, and
    // the generated version.ts, which lands under bazel-bin, where the indexer doesn't see it (see below).
    let built: Vec<&String> = progress.iter().filter(|m| m.contains("for the TypeScript index")).filter(|m| !m.starts_with("Building")).collect();
    for side in ["head", "base"] {
        let line = built.iter().find(|m| m.starts_with(side)).unwrap_or_else(|| panic!("no build line for {side}: {progress:?}"));
        assert!(
            line.contains("Bazel builds 3 npm links for the TypeScript index and 1 generated TypeScript file")
                && line.ends_with(": //:node_modules/@types/semver //:node_modules/typescript //packages/app:node_modules/@demo/lib //packages/app:src/generated/version.ts"),
            "{line}"
        );
    }

    // Components are the ts_project targets, which compile the packages their package.json names.
    for (id, module) in [("//packages/app:app", "@demo/app"), ("//packages/lib:lib", "@demo/lib")] {
        assert!(report.components.iter().any(|c| c.id == id && c.module.as_deref() == Some(module)), "no component {id}: {:?}", report.components);
    }
    let edge = |to: &str| report.edges.iter().any(|e| e.from == "//packages/app:app" && e.to == to);
    assert!(edge("//packages/lib:lib") && edge("ext:semver"), "{:?}", report.edges);

    assert_eq!(used_by(report, "Store.load()"), ["start()"]);
    assert_eq!(used_by(report, "Cache.load()"), Vec::<String>::new(), "the app never calls Cache.load()");
    let named = session.name_based_report();
    assert!(!used_by(&named, "Cache.load()").is_empty(), "name matching can't tell the two load() methods apart");

    // CORE-003: store.ts and cache.ts each declare an interface Source. scip-typescript resolves the
    // `implements` clauses, so only LocalSource implements store.ts's, whose requirement head changes.
    let fetch = report.review_items.iter().find(|i| i.qualified_name.starts_with("Source.fetch") && i.location.file == "packages/lib/src/store.ts").expect("the changed requirement");
    let context: Vec<(&str, u32)> =
        report.regions.iter().filter(|r| r.review_item == fetch.id && r.relation.as_deref() == Some("conformer")).map(|r| (r.file.as_str(), r.start_line)).collect();
    assert_eq!(context, [("packages/app/src/main.ts", 13)], "{:?}", report.regions);

    // build_info.ts imports a file only the build has: syntax-only at both sides, and the warning says why.
    // Its call of Store.load() is not counted, and the checks that claim "no callers" are held back.
    let partial: Vec<&str> = report.warnings.iter().filter(|w| w.kind == "index-partial").map(|w| w.message.as_str()).collect();
    assert!(partial.iter().any(|m| m.contains("packages/app/src/build_info.ts imports ./generated/version")), "{partial:#?}");
    let coverage = report.analysis.languages.iter().find(|l| l.id == "typescript").expect("TypeScript's coverage");
    assert_eq!((coverage.files, coverage.indexed_files), (5, 4));
    assert!(coverage.held_back.contains(&"unused-api".to_string()), "{coverage:?}");
    // A conformer could sit in build_info.ts too, so the conformers check is held back as well.
    assert!(coverage.held_back.contains(&"conformers".to_string()) && findings(report, "conformers").is_empty(), "{coverage:?}");

    // CORE-002, and the links made for the indexer are gone from the app's own tree.
    assert_eq!(snapshot(&repo.path()), before, "nothing in the reviewed repository changed");
    let bazel_dir = bazel.home.join("cache/bazel");
    let mut leftovers: Vec<String> = Vec::new();
    for entry in std::fs::read_dir(&bazel_dir).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().starts_with("ts-bazel")) {
        for side in ["head", "base"] {
            for dir in ["", "packages/app", "packages/lib"] {
                let modules = entry.path().join(side).join("tree").join(dir).join("node_modules");
                if std::fs::symlink_metadata(&modules).is_ok() {
                    leftovers.push(modules.display().to_string());
                }
            }
        }
    }
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

/// Cancelling stops the review's Bazel commands, which run several at a time (`bazel::jobs`), within two
/// seconds, during the graph queries and during the index builds alike. The review then ends with its final
/// report, in which TypeScript is syntax-only because indexing was cancelled (CORE-003).
#[test]
fn cancelling_stops_every_bazel_command_and_ends_syntax_only() {
    use reviewmap_core::proc::Cancel;
    use reviewmap_core::session::{self, Event};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    let Some(bazel) = bazel() else { return };
    let Some(bazel_tool) = reviewmap_core::tools::bazel() else { return };
    if reviewmap_core::tools::node().is_none() {
        eprintln!("skipped: Node.js was not found");
        return;
    }
    let repo = fixture_repo_at(&own_fixture("ts-bazel"), &bazel.home.join("repos/ts-bazel"));
    let graph_step = |m: &str| m.starts_with("Asking Bazel for the head build graph");
    let index_step = |m: &str| m.starts_with("Building head") && m.contains("for the TypeScript index");
    for (step, during) in [("graph", &graph_step as &(dyn Fn(&str) -> bool + Sync)), ("index", &index_step)] {
        // Nothing cached, so the step runs Bazel.
        let _ = std::fs::remove_dir_all(bazel.home.join("cache/graphs"));
        let _ = std::fs::remove_dir_all(bazel.home.join("cache/index/typescript"));
        let cancel = Cancel::new();
        let cancelled_at: Arc<std::sync::Mutex<Option<Instant>>> = Arc::default();
        let reports = std::sync::Mutex::new(Vec::new());
        let progress = std::sync::Mutex::new(Vec::new());
        let emit = |event: Event| match event {
            Event::Report(report) => reports.lock().unwrap().push(*report),
            // A moment after the step's command starts, so that it is running.
            Event::Progress(message) if during(&message) => {
                progress.lock().unwrap().push(message);
                let (cancel, at) = (cancel.clone(), cancelled_at.clone());
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(300));
                    *at.lock().unwrap() = Some(Instant::now());
                    cancel.cancel();
                });
            }
            Event::Progress(message) => progress.lock().unwrap().push(message),
        };
        session::run(request(&repo), &cancel, &emit).expect("a cancelled review ends with a report");
        let stopped = Instant::now();
        let at = cancelled_at.lock().unwrap().unwrap_or_else(|| panic!("the {step} step never ran Bazel, so nothing was cancelled"));
        let took = stopped.duration_since(at);
        eprintln!("cancelled during the {step} step: the review ended {:.2} s later", took.as_secs_f64());
        assert!(took < Duration::from_secs(3), "the {step} step went on for {took:?} after cancelling");

        let reports = reports.into_inner().unwrap();
        let progress = progress.into_inner().unwrap();
        // The step was stopped in the middle: the graph queries never returned a graph, and the index build
        // never got as far as scip-typescript.
        if step == "graph" {
            assert_eq!(stages(&reports), ["preliminary", "complete"], "the graph query was interrupted: {progress:?}");
        } else {
            assert!(!progress.iter().any(|m| m.starts_with("Indexing head")), "the build was interrupted before scip-typescript: {progress:?}");
        }
        let report = reports.last().expect("a report");
        assert_eq!(report.analysis.stage, "complete", "the report after cancelling is final");
        assert!(
            report.warnings.iter().any(|w| w.kind == "index-unavailable" && w.message.contains("TypeScript") && w.message.contains("indexing was cancelled")),
            "{step}: {:?}",
            report.warnings
        );
        assert_eq!(report.analyzer.resolution, "syntax", "{step}");

        // No Bazel server of the review is still busy: a command in its output base runs at once, without
        // "Another command is running".
        let bazel_dir = bazel.home.join("cache/bazel");
        for entry in std::fs::read_dir(&bazel_dir).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().starts_with("ts-bazel")) {
            for side in ["head", "base"] {
                let output_base = entry.path().join(side).join("out/_root");
                if !output_base.join("server").exists() {
                    continue;
                }
                let info = std::process::Command::new(&bazel_tool)
                    .arg(format!("--output_base={}", output_base.display()))
                    .args(["info", "output_base"])
                    .current_dir(entry.path().join(side).join("tree"))
                    .output()
                    .expect("bazel info runs");
                let stderr = String::from_utf8_lossy(&info.stderr);
                assert!(!stderr.contains("Another command"), "{step}: the {side} server was still busy: {stderr}");
            }
        }
    }
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

/// Needs no tools: a rules_ts workspace without Bazel ends syntax-only for TypeScript and says why (CORE-003).
#[test]
fn without_bazel_a_rules_ts_workspace_stays_syntax_only() {
    let _guard = BAZEL.lock().unwrap_or_else(|e| e.into_inner());
    home(Some("reviewmap-test-home"));
    let repo = fixture_repo(&own_fixture("ts-bazel"));
    std::env::set_var("REVIEWMAP_BAZEL", "reviewmap-no-such-bazel");
    let report = analyze(request(&repo));
    std::env::remove_var("REVIEWMAP_BAZEL");
    assert_eq!(report.analysis.stage, "complete");
    assert_eq!(report.analyzer.resolution, "syntax");
    assert!(
        report.warnings.iter().any(|w| w.kind == "index-unavailable" && w.message.contains("TypeScript") && w.message.contains("rules_ts") && w.message.contains("Bazel was not found")),
        "{:?}",
        report.warnings
    );
    assert!(report.review_items.iter().all(|i| i.used_by.is_empty()), "nothing is linked by name");
    // The app imports @demo/lib by name: syntax links the two packages.
    assert!(report.edges.iter().any(|e| e.from == "npm:@demo/app" && e.to == "npm:@demo/lib"), "{:?}", report.edges);
}
