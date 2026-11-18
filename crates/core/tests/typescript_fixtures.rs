//! TypeScript outside Bazel, from start to end: `tests/fixtures/ts-yarn`, a Yarn Classic workspace with
//! three packages, and `tests/fixtures/ts-berry`, the same workspace in Yarn 4 with its default linker,
//! Plug'n'Play. Name matching gets its common member name wrong (`load()` on Store and Cache, where the
//! app only calls Store's), and one file imports a workspace package whose `types` entry is an unbuilt
//! `dist/`, which the index can't see. Rules_ts workspaces are covered in `bazel_fixtures.rs`.
//!
//! The tests that index need Node.js and return early, saying why, without it; the first run fetches Yarn
//! Classic and Yarn 4 (through corepack) and scip-typescript (through npx), so it needs the network once.
//! The fallback and package-manager tests need no tools.

mod common;

use common::*;
use reviewmap_core::model::ChangeReport;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

/// The tests change environment variables that the others read, so they run one at a time.
static ENV: Mutex<()> = Mutex::new(());

fn lock() -> MutexGuard<'static, ()> {
    ENV.lock().unwrap_or_else(|e| e.into_inner())
}

/// Sets an environment variable for the length of a test.
struct Var(&'static str);

impl Var {
    fn set(name: &'static str, value: &str) -> Var {
        std::env::set_var(name, value);
        Var(name)
    }
}

impl Drop for Var {
    fn drop(&mut self) {
        std::env::remove_var(self.0);
    }
}

fn node() -> bool {
    let found = reviewmap_core::tools::node().is_some();
    if !found {
        eprintln!("skipped: Node.js was not found");
    }
    found
}

fn used_by(report: &ChangeReport, name: &str) -> Vec<String> {
    let mut symbols: Vec<String> = review_item(report, name).used_by.iter().map(|u| u.symbol.clone()).collect();
    symbols.sort();
    symbols
}

fn has_edge(report: &ChangeReport, from: &str, to: &str) -> bool {
    report.edges.iter().any(|e| e.from == from && e.to == to)
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

fn typescript_warnings(report: &ChangeReport) -> Vec<String> {
    report.warnings.iter().filter(|w| w.kind.starts_with("index-")).map(|w| format!("{}: {}", w.kind, w.message)).collect()
}

/// Parsing and components need no index: packages are components, a test file goes to its package's test
/// component, and imports give the links that syntax proves, through a workspace package's entry and a
/// tsconfig `paths` alias.
#[test]
fn yarn_workspace_components_and_imports() {
    let _guard = lock();
    let repo = fixture_repo(&own_fixture("ts-yarn"));
    let mut request = request(&repo);
    request.index = Some(false);
    let report = analyze(request);
    let ids: Vec<&str> = report.components.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(ids, ["npm:@demo/app", "npm:@demo/app:tests", "npm:@demo/lib", "npm:@demo/proto"]);
    assert!(report.components.iter().any(|c| c.id == "npm:@demo/lib" && c.module.as_deref() == Some("@demo/lib")));
    assert!(has_edge(&report, "npm:@demo/app", "npm:@demo/lib"));
    assert!(has_edge(&report, "npm:@demo/app", "npm:@demo/proto"), "the import of a package with an unbuilt entry still names the package");
    assert!(has_edge(&report, "npm:@demo/app:tests", "npm:@demo/app"));
    assert_eq!(changes(&report).keys().cloned().collect::<Vec<_>>(), ["Cache.load()", "Store.load()", "Store.reset()", "label()", "send()"]);
    assert_eq!(report.analyzer.resolution, "syntax");
    assert!(report.review_items.iter().all(|i| i.used_by.is_empty()), "syntax links no calls");
}

/// The index from start to end: Yarn installs in the app's own tree with scripts off, scip-typescript
/// indexes it, and references are exact.
#[test]
fn yarn_workspace_index() {
    let _guard = lock();
    if !node() {
        return;
    }
    let repo = fixture_repo(&own_fixture("ts-yarn"));
    let before = snapshot(&repo.path());
    let (session, reports, progress) = run(request(&repo));
    let report = reports.last().expect("a report");
    if report.warnings.iter().any(|w| w.kind == "index-unavailable" && (w.message.contains("could not") || w.message.contains("failed"))) {
        eprintln!("skipped: the TypeScript tools could not be fetched: {:?}", report.warnings);
        return;
    }
    assert_eq!(report.analyzer.resolution, "index", "{:?}", report.warnings);
    assert!(progress.iter().any(|m| m.starts_with("Installing head") && m.contains("scripts off")), "{progress:?}");

    // Store.load() and Cache.load() share a name; the app only calls Store's.
    assert_eq!(used_by(report, "Store.load()"), ["start()"]);
    assert_eq!(used_by(report, "Cache.load()"), Vec::<String>::new(), "the app never calls Cache.load()");
    let named = session.name_based_report();
    assert_eq!(named.analysis.variant, "name-based");
    assert_eq!(used_by(&named, "Cache.load()"), ["start()"], "name matching can't tell the two load() methods apart");

    // wire.ts imports @demo/proto, whose types entry is an unbuilt dist/: its references are incomplete, so
    // it is syntax-only at both sides, the warning says which import and why, and since a caller could sit
    // there, the checks that claim "no callers" don't run. Store.reset() is only called from wire.ts.
    let warnings = typescript_warnings(report);
    assert!(warnings.iter().any(|w| w.contains("packages/app/src/wire.ts imports @demo/proto") && w.contains("not in the repository")), "{warnings:#?}");
    assert!(warnings.iter().any(|w| w.contains("postinstall of @demo/proto")), "{warnings:#?}");
    assert!(!warnings.iter().any(|w| w.starts_with("index-unavailable")), "{warnings:#?}");
    let coverage = report.analysis.languages.iter().find(|l| l.id == "typescript").expect("TypeScript's coverage");
    assert_eq!((coverage.resolution.as_str(), coverage.files, coverage.indexed_files), ("index", 7, 6));
    assert!(coverage.held_back.contains(&"unused-api".to_string()), "{coverage:?}");
    assert!(!report.findings.iter().any(|f| f.kind == "unused-api" || f.kind == "orphaned"), "{:?}", report.findings);
    assert!(review_item(report, "Store.reset()").used_by.is_empty(), "no name-matched use from the uncovered file");

    // CORE-002: the install and the index ran in the app's own copies.
    assert_eq!(snapshot(&repo.path()), before, "nothing in the reviewed repository changed");

    // Another review of the same commits reads the kept index.
    let (_, again, progress) = run(request(&repo));
    assert!(progress.iter().any(|m| m.starts_with("TypeScript index for head") && m.ends_with("cached")), "{progress:?}");
    let again = again.last().unwrap();
    assert_eq!(again.edges, report.edges);
    assert_eq!(again.review_items, report.review_items);
}

/// When indexing fails, TypeScript ends syntax-only and says why (CORE-003): no Node.js here.
#[test]
fn without_node_the_review_stays_syntax_only() {
    let _guard = lock();
    let repo = fixture_repo(&own_fixture("ts-yarn"));
    let _node = Var::set("REVIEWMAP_NODE", "reviewmap-no-such-node");
    let report = analyze(request(&repo));
    assert_eq!(report.analysis.stage, "complete");
    assert_eq!(report.analyzer.resolution, "syntax");
    assert!(
        report.warnings.iter().any(|w| w.kind == "index-unavailable" && w.message.contains("TypeScript") && w.message.contains("Node.js")),
        "{:?}",
        report.warnings
    );
    assert!(report.review_items.iter().all(|i| i.used_by.is_empty()), "nothing is linked by name");
    assert!(has_edge(&report, "npm:@demo/app", "npm:@demo/lib"), "imports still link the packages");
    assert!(!report.findings.iter().any(|f| matches!(f.kind.as_str(), "unused-api" | "orphaned" | "untested")), "{:?}", report.findings);
}

/// An indexer that fails leaves the same syntax-only report, with the indexer's failure as the reason.
#[test]
fn a_failing_indexer_leaves_a_syntax_only_report() {
    let _guard = lock();
    if !node() {
        return;
    }
    let repo = fixture_repo(&own_fixture("ts-yarn"));
    let _indexer = Var::set("REVIEWMAP_SCIP_TYPESCRIPT", "false");
    let report = analyze(request(&repo));
    assert_eq!(report.analyzer.resolution, "syntax", "{:?}", report.warnings);
    assert!(report.warnings.iter().any(|w| w.kind == "index-unavailable" && w.message.contains("scip-typescript failed")), "{:?}", report.warnings);
    assert!(report.review_items.iter().all(|i| i.used_by.is_empty()));
}

const APP: &str = "import { Store } from \"./store\";\n\nexport function start(): number {\n  return new Store().load();\n}\n";
const STORE: &str = "export class Store {\n  load(): number {\n    return 1;\n  }\n}\n";
const PNP: &str = "// A committed Plug'n'Play loader.\n";
const STORE_HEAD: &str = "export class Store {\n  load(): number {\n    return 2;\n  }\n}\n";

/// A Yarn Berry workspace whose own linker is Plug'n'Play is installed with the node-modules linker in the
/// app's own tree, with the project's Yarn and scripts off, and indexed like a Classic one.
#[test]
fn yarn_berry_workspace_index() {
    let _guard = lock();
    if !node() {
        return;
    }
    let fixture = own_fixture("ts-berry");
    let repo = fixture_repo(&fixture);
    let before = snapshot(&repo.path());
    let (_, reports, progress) = run(request(&repo));
    let report = reports.last().expect("a report");
    if report.warnings.iter().any(|w| w.kind == "index-unavailable" && (w.message.contains("could not") || w.message.contains("failed"))) {
        eprintln!("skipped: the TypeScript tools could not be fetched: {:?}", report.warnings);
        return;
    }
    assert_eq!(report.analyzer.resolution, "index", "{:?}", report.warnings);
    assert!(progress.iter().any(|m| m.starts_with("Installing head") && m.contains("Yarn Berry") && m.contains("scripts off")), "{progress:?}");
    let warnings = typescript_warnings(report);
    assert!(!warnings.iter().any(|w| w.contains("could not be installed")), "{warnings:#?}");
    assert_eq!(used_by(report, "Store.load()"), ["start()"]);
    assert_eq!(used_by(report, "Cache.load()"), Vec::<String>::new(), "the app never calls Cache.load()");

    // CORE-002: the install ran in the app's own copies, and left every tracked file there as committed
    // (with the node-modules linker Yarn would rewrite manifests and drop a committed .pnp.cjs).
    assert_eq!(snapshot(&repo.path()), before, "nothing in the reviewed repository changed");
    let trees = reviewmap_core::store::cache_root().join("bazel").join(reviewmap_core::store::repo_key(&repo.path()));
    for side in ["base", "head"] {
        let tree = trees.join(side).join("tree");
        assert!(tree.join("node_modules/@demo/lib").exists(), "{side}: workspace packages are linked in node_modules");
        assert!(!tree.join(".pnp.cjs").exists(), "{side}: no Plug'n'Play loader");
        for (file, _) in snapshot(&fixture.join(side)).into_iter().filter(|(_, what)| what != "directory") {
            let want = std::fs::read(fixture.join(side).join(&file)).unwrap();
            assert_eq!(std::fs::read(tree.join(&file)).ok(), Some(want), "{side}: {file} is as committed");
        }
    }

    // Another review of the same commits reads the kept index.
    let (_, again, progress) = run(request(&repo));
    assert!(progress.iter().any(|m| m.starts_with("TypeScript index for head") && m.ends_with("cached")), "{progress:?}");
    let again = again.last().unwrap();
    assert_eq!(again.edges, report.edges);
    assert_eq!(again.review_items, report.review_items);
}

/// A Yarn Berry project without Node.js ends syntax-only, and the reason is Node.js.
#[test]
fn a_yarn_berry_project_without_node_is_syntax_only() {
    let _guard = lock();
    let base: Vec<(&str, &str)> = vec![
        ("web/package.json", "{\"name\": \"web\", \"packageManager\": \"yarn@4.5.0\"}"),
        ("web/yarn.lock", "# This file is generated by running \"yarn install\" inside your project.\n\n__metadata:\n  version: 8\n"),
        ("web/.yarnrc.yml", "nodeLinker: node-modules\n"),
        ("web/src/app.ts", APP),
        ("web/src/store.ts", STORE),
    ];
    let repo = two_commits(&base, &[("web/src/store.ts", Some(STORE_HEAD))]);
    let _node = Var::set("REVIEWMAP_NODE", "reviewmap-no-such-node");
    let report = analyze(request(&repo));
    assert_eq!(report.analysis.stage, "complete");
    assert_eq!(report.analyzer.resolution, "syntax");
    let warning = report.warnings.iter().find(|w| w.kind == "index-unavailable" && w.message.contains("TypeScript")).expect("a coverage warning");
    assert!(warning.message.contains("Node.js") && !warning.message.contains("Yarn Berry"), "{}", warning.message);
    assert!(review_item(&report, "Store.load()").used_by.is_empty());
}

/// A project that moved from Yarn Classic to Berry is indexed at both sides, each with its own Yarn. Head's
/// lockfile is in a Yarn 4 format and pins no Yarn, so the pinned Yarn 4 installs it; it would write another
/// format, so the immutable install fails and the install runs again without --immutable. Head commits a
/// `.pnp.cjs`, which Yarn deletes under the node-modules linker; the app's tree gets it back.
#[test]
fn a_project_that_is_classic_at_base_and_berry_at_head_is_indexed_at_both() {
    let _guard = lock();
    if !node() {
        return;
    }
    let base: Vec<(&str, &str)> = vec![
        ("package.json", "{\"name\": \"web\"}"),
        ("yarn.lock", "# yarn lockfile v1\n\n\n"),
        ("src/app.ts", APP),
        ("src/store.ts", STORE),
    ];
    let head: Vec<(&str, Option<&str>)> = vec![
        ("yarn.lock", Some("__metadata:\n  version: 8\n  cacheKey: 10c0\n\n\"web@workspace:.\":\n  version: 0.0.0-use.local\n  resolution: \"web@workspace:.\"\n  languageName: unknown\n  linkType: soft\n")),
        ("src/store.ts", Some(STORE_HEAD)),
        (".pnp.cjs", Some(PNP)),
    ];
    let repo = two_commits(&base, &head);
    let before = snapshot(&repo.path());
    let (_, reports, progress) = run(request(&repo));
    let report = reports.last().expect("a report");
    if report.warnings.iter().any(|w| w.kind == "index-unavailable" && (w.message.contains("could not") || w.message.contains("failed"))) {
        eprintln!("skipped: the TypeScript tools could not be fetched: {:?}", report.warnings);
        return;
    }
    assert_eq!(report.analyzer.resolution, "index", "{:?}", report.warnings);
    assert!(progress.iter().any(|m| m.starts_with("Installing base") && m.contains("(Yarn, scripts off)")), "{progress:?}");
    assert!(progress.iter().any(|m| m.starts_with("Installing head") && m.contains("Yarn Berry")), "{progress:?}");
    assert!(progress.iter().any(|m| m.starts_with("The immutable install of head") && m.contains("without --immutable")), "{progress:?}");
    let warnings = typescript_warnings(report);
    assert!(!warnings.iter().any(|w| w.contains("could not be installed") || w.starts_with("index-unavailable")), "{warnings:#?}");
    // A unit is indexed at both sides or at neither, so full coverage means both.
    let coverage = report.analysis.languages.iter().find(|l| l.id == "typescript").expect("TypeScript's coverage");
    assert_eq!((coverage.resolution.as_str(), coverage.files, coverage.indexed_files), ("index", 2, 2));
    assert_eq!(snapshot(&repo.path()), before, "nothing in the reviewed repository changed");
    let head_tree = reviewmap_core::store::cache_root().join("bazel").join(reviewmap_core::store::repo_key(&repo.path())).join("head/tree");
    assert_eq!(std::fs::read_to_string(head_tree.join(".pnp.cjs")).ok().as_deref(), Some(PNP), "the committed .pnp.cjs is back");
    assert_eq!(std::fs::read_to_string(head_tree.join("package.json")).ok().as_deref(), Some("{\"name\": \"web\"}"), "no packageManager added");
}

/// pnpm and npm projects outside Bazel are outside phase 1: syntax-only, with the reason.
#[test]
fn other_package_managers_are_not_indexed() {
    let _guard = lock();
    let base: Vec<(&str, &str)> = vec![("package.json", "{\"name\": \"web\"}"), ("pnpm-lock.yaml", "lockfileVersion: '9.0'\n"), ("src/app.ts", APP), ("src/store.ts", STORE)];
    let repo = two_commits(&base, &[("src/store.ts", Some(STORE_HEAD))]);
    let report = analyze(request(&repo));
    assert_eq!(report.analyzer.resolution, "syntax");
    assert!(report.warnings.iter().any(|w| w.kind == "index-unavailable" && w.message.contains("uses pnpm")), "{:?}", report.warnings);
    // The relative import is a link syntax proves, inside one component; nothing is matched by name.
    assert!(review_item(&report, "Store.load()").used_by.is_empty());
}

/// The prototype's TypeScript fixture (an npm workspace with React, zod, a tsconfig project, and scripts):
/// the rebuild finds the same dependencies and the same contract flags as the prototype's snapshot.
#[test]
fn the_prototype_fixture_keeps_its_dependencies_and_contract_flags() {
    let _guard = lock();
    let repo = fixture_repo(&prototype_fixture("typescript"));
    let mut request = request(&repo);
    request.index = Some(false);
    let report = analyze(request);
    let expected: serde_json::Value = serde_json::from_slice(&std::fs::read(prototype_fixture("typescript").join("expected.json")).unwrap()).unwrap();
    let edges = |list: Vec<(String, String, String)>| list.into_iter().collect::<std::collections::BTreeSet<_>>();
    let want = edges(
        expected["edges"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| (e["from"].as_str().unwrap().to_string(), e["to"].as_str().unwrap().to_string(), e["status"].as_str().unwrap().to_string()))
            .collect(),
    );
    let have = edges(report.edges.iter().map(|e| (e.from.clone(), e.to.clone(), serde_json::to_value(e.status).unwrap().as_str().unwrap().to_string())).collect());
    assert_eq!(have, want);
    let mut flagged = 0;
    for item in expected["reviewItems"].as_array().unwrap() {
        let name = item["qualifiedName"].as_str().unwrap();
        let component = item["component"].as_str().unwrap();
        let mut want: Vec<String> = item["contractFlags"].as_array().map(|a| a.iter().map(|f| f.as_str().unwrap().to_string()).collect()).unwrap_or_default();
        // The prototype had one build settings review item per target; the rebuild has one for each file
        // that sets a changed setting, "<target> build settings (<file>)", so their flags are compared together.
        let split = format!("{name} (");
        let ours: Vec<&reviewmap_core::model::ReviewItem> = report
            .review_items
            .iter()
            .filter(|i| i.component == component && (i.qualified_name == name || (name.ends_with(" build settings") && i.qualified_name.starts_with(&split))))
            .collect();
        assert!(!ours.is_empty(), "no review item {name} in {component}");
        let mut have: Vec<String> = ours.iter().flat_map(|i| i.contract_flags.clone()).collect();
        want.sort();
        have.sort();
        assert_eq!(have, want, "contract flags of {name}");
        flagged += !want.is_empty() as usize;
    }
    assert!(flagged >= 10, "the snapshot has flags to compare ({flagged})");
    assert!(review_item(&report, "CartRepository").contract_flags.contains(&"typescript:interface-member-added".to_string()));
}

/// CORE-006 for TypeScript: `format()` in money.ts only changed its formatting.
#[test]
fn core_006_a_cosmetic_typescript_review_item_asks_for_no_review() {
    let _guard = lock();
    let repo = fixture_repo(&prototype_fixture("typescript"));
    let mut request = request(&repo);
    request.index = Some(false);
    let report = analyze(request);
    let cosmetic = report
        .review_items
        .iter()
        .find(|i| i.qualified_name == "format()" && i.id.starts_with("packages/core/src/money.ts::"))
        .expect("format() in money.ts");
    assert_eq!(cosmetic.change, reviewmap_core::model::ChangeKind::Cosmetic);
    assert!(!report.regions.iter().any(|r| r.review_item == cosmetic.id), "no regions");
    assert!(!report.findings.iter().any(|f| f.anchors.iter().any(|a| a.review_item.as_deref() == Some(cosmetic.id.as_str()))), "no findings");
    let component = report.components.iter().find(|c| c.id == cosmetic.component).expect("its component");
    let changed = report.review_items.iter().filter(|i| i.component == cosmetic.component && i.change != reviewmap_core::model::ChangeKind::Cosmetic).count();
    assert_eq!(component.changed_review_items, changed, "not counted as changed");
}

/// The regions of a review item, in order.
fn regions_of<'a>(report: &'a ChangeReport, id: &str) -> Vec<&'a reviewmap_core::model::Region> {
    report.regions.iter().filter(|r| r.review_item == id).collect()
}

/// The 1-based line of the first line of `text` that contains `needle`.
fn line_of(text: &str, needle: &str) -> u32 {
    text.lines().position(|l| l.contains(needle)).map(|i| i as u32 + 1).unwrap_or_else(|| panic!("no {needle}"))
}

/// Settings of one package in two files make one review item per file, each region in its item's file and
/// naming only its own setting. A package.json field is found at the top level, not inside `exports`, and a
/// removed tsconfig option is shown at its base line.
#[test]
fn build_settings_in_two_files_are_shown_where_each_is_set() {
    let _guard = lock();
    let package_base = r#"{
  "name": "@shop/core",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "default": "./dist/index.js"
    }
  },
  "types": "./dist/index.d.ts"
}
"#;
    let package_head = package_base.replace("  \"types\": \"./dist/index.d.ts\"\n", "  \"types\": \"./dist/types/index.d.ts\"\n");
    let tsconfig_base = r#"{
  "compilerOptions": {
    "strict": false,
    "noImplicitAny": true,
    "target": "ES2022"
  }
}
"#;
    let tsconfig_head = r#"{
  "compilerOptions": {
    "strict": true,
    "target": "ES2022"
  }
}
"#;
    let repo = two_commits(
        &[("core/package.json", package_base), ("core/tsconfig.json", tsconfig_base), ("core/src/index.ts", "export const a = 1;\n")],
        &[("core/package.json", Some(&package_head)), ("core/tsconfig.json", Some(tsconfig_head))],
    );
    let mut request = request(&repo);
    request.index = Some(false);
    let report = analyze(request);
    let items: Vec<&reviewmap_core::model::ReviewItem> = report.review_items.iter().filter(|i| i.kind == reviewmap_core::model::ItemKind::Target).collect();
    assert_eq!(items.len(), 2, "{:?}", items.iter().map(|i| &i.qualified_name).collect::<Vec<_>>());
    for item in &items {
        for r in regions_of(&report, &item.id) {
            assert_eq!(r.file, item.location.file, "region {} is in its item's file", r.id);
        }
    }

    let package = review_item(&report, "@shop/core build settings (package.json)");
    let types = package_head.lines().collect::<Vec<_>>().iter().rposition(|l| l.contains("\"types\"")).unwrap() as u32 + 1;
    assert_eq!((package.location.file.as_str(), package.location.start_line), ("core/package.json", types));
    let regions = regions_of(&report, &package.id);
    assert_eq!(regions.iter().map(|r| (r.kind.as_str(), r.start_line, r.side)).collect::<Vec<_>>(), vec![("review", types, reviewmap_core::model::Side::Head)]);
    assert_eq!(regions[0].reasons, vec!["typescript:package-exports-changed".to_string()]);

    let tsconfig = review_item(&report, "@shop/core build settings (tsconfig.json)");
    let strict = line_of(tsconfig_head, "\"strict\"");
    let removed = line_of(tsconfig_base, "\"noImplicitAny\"");
    assert_eq!((tsconfig.location.file.as_str(), tsconfig.location.side), ("core/tsconfig.json", reviewmap_core::model::Side::Head));
    assert!(tsconfig.location.start_line <= strict && strict <= tsconfig.location.end_line);
    let regions = regions_of(&report, &tsconfig.id);
    let shown: Vec<(&str, u32, reviewmap_core::model::Side, Option<u32>)> = regions.iter().map(|r| (r.kind.as_str(), r.start_line, r.side, r.anchor)).collect();
    assert_eq!(shown, vec![("review", strict, reviewmap_core::model::Side::Head, None), ("removed", removed, reviewmap_core::model::Side::Base, Some(strict))]);
    assert_eq!(regions[0].reasons, vec!["typescript:strictness-changed".to_string()]);
    assert!(tsconfig.base_location.as_ref().map(|b| b.file == "core/tsconfig.json" && b.start_line <= removed && removed <= b.end_line).unwrap_or(false), "{:?}", tsconfig.base_location);
}
