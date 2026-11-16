//! Acceptance tests for the core rules (statute/rules/core.md) in the rebuild. Each test names its rule.
//! They need `git` and nothing else: the sources are Kotlin, which is parsed in-process, and no test here
//! starts Bazel. The CORE-004 tests and the LLM half of CORE-005 run `scripts/fake-llm.sh`, or a wrapper
//! around it, in place of `claude`: no test here runs a real coding agent.
//! `swift_rules.rs` repeats what depends on the language for Swift, and `bazel_fixtures.rs` covers the
//! index builds.

mod common;

use common::*;
use reviewmap_core::index::{IndexedRef, SideIndex};
use reviewmap_core::model::{ChangeKind, ChangeReport, Warning};
use std::collections::{BTreeMap, BTreeSet};

// MARK: CORE-001 A change is measured from the merge-base

/// `main` gets `Main.kt` after `feature` branched off, so `main` has moved on since the branch point.
fn moved_on() -> TestRepo {
    let repo = TestRepo::new();
    repo.write("lib/Shared.kt", "class Shared\n");
    repo.commit("shared");
    repo.git(&["checkout", "-qb", "feature"]);
    repo.write("lib/Feature.kt", "class Feature\n");
    repo.commit("feature");
    repo.git(&["checkout", "-q", "main"]);
    repo.write("lib/Main.kt", "class OnlyOnMain\n");
    repo.commit("main moves on");
    repo
}

#[test]
fn core_001_the_base_is_the_merge_base() {
    let repo = moved_on();
    let report = analyze(request(&repo));
    assert!(report.repo.uses_merge_base);
    assert_eq!(report.repo.base_sha, repo.sha("main~1"), "the branch point, not the tip of main");
    assert_eq!(report.repo.head_sha, repo.sha("feature"));
    assert_eq!(changes(&report).get("Feature"), Some(&ChangeKind::Added));
    assert_eq!(changes(&report).get("OnlyOnMain"), None, "main's later commit is not shown as the branch removing it");
}

#[test]
fn core_001_no_merge_base_compares_against_the_base_itself() {
    let repo = moved_on();
    let mut request = request(&repo);
    request.use_merge_base = false;
    let report = analyze(request);
    assert!(!report.repo.uses_merge_base);
    assert_eq!(report.repo.base_sha, repo.sha("main"));
    assert_eq!(changes(&report).get("Feature"), Some(&ChangeKind::Added));
    assert_eq!(changes(&report).get("OnlyOnMain"), Some(&ChangeKind::Removed));
}

// MARK: CORE-002 Analysis never writes into the reviewed repo

/// Every file and directory under a path, `.git` included, with its size and modification time.
fn snapshot(root: &std::path::Path) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
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

#[test]
fn core_002_analysis_leaves_the_repo_untouched() {
    let repo = moved_on();
    repo.git(&["checkout", "-q", "feature"]);
    repo.write("lib/Uncommitted.kt", "class Uncommitted\n");
    let before = snapshot(&repo.path());
    let report = analyze(request(&repo));
    assert_eq!(changes(&report).get("Feature"), Some(&ChangeKind::Added));
    assert_eq!(changes(&report).get("Uncommitted"), None, "only committed trees are analyzed");
    assert_eq!(snapshot(&repo.path()), before, "nothing in the working tree or in .git changed");
    // What the analysis keeps is under the app's own roots.
    assert!(!reviewmap_core::store::cache_root().starts_with(repo.path()));
    assert!(!reviewmap_core::store::data_root().starts_with(repo.path()));
}

#[test]
fn core_002_reviewmap_yml_is_read_from_the_head_commit() {
    let repo = two_commits(
        &[("lib/Shared.kt", "class Shared\n"), ("reviewmap.yml", "exclude: [\"skipped/**\"]\n")],
        &[("lib/Feature.kt", Some("class Feature\n")), ("skipped/Skipped.kt", Some("class Skipped\n"))],
    );
    // The working tree's file says something else; it is not what the review reads.
    repo.write("reviewmap.yml", "exclude: [\"lib/**\"]\n");
    let report = analyze(request(&repo));
    assert_eq!(changes(&report).get("Feature"), Some(&ChangeKind::Added));
    assert_eq!(changes(&report).get("Skipped"), None, "the committed reviewmap.yml excludes it");
}

// MARK: CORE-003 Without an index, a language shows only what syntax proves, and the report says so

/// `Format.legacy` is called from two components, `app` and `other`. Head removes the call in `other`.
/// The import is a link that syntax proves; the call at line 6 is one that only name matching or an index finds.
fn two_callers() -> TestRepo {
    two_commits(
        &[
            ("lib/Format.kt", "package lib\n\nobject Format {\n    internal fun legacy(s: String): String = s\n}\n"),
            ("app/App.kt", "package app\n\nimport lib.Format\n\nfun show() {\n    println(Format.legacy(\"a\"))\n}\n"),
            ("other/Other.kt", "package other\n\nimport lib.Format\n\nfun other() {\n    println(Format.legacy(\"b\"))\n}\n"),
        ],
        &[("other/Other.kt", Some("package other\n\nfun other() {\n    println(\"b\")\n}\n"))],
    )
}

fn index_warnings(report: &ChangeReport) -> Vec<&Warning> {
    report.warnings.iter().filter(|w| w.kind.starts_with("index-")).collect()
}

fn held_back_warnings(report: &ChangeReport) -> Vec<&Warning> {
    report.warnings.iter().filter(|w| w.kind == "checks-held-back").collect()
}

/// Whether the report links `app` to `lib` through the call at line 6 of app/App.kt.
fn has_call_link(report: &ChangeReport) -> bool {
    report.edges.iter().any(|e| e.from == "folder:app" && e.to == "folder:lib" && e.refs.iter().any(|r| r.file == "app/App.kt" && r.line == 6))
}

/// Whether `app` still links to `lib` through its import, a link that syntax proves.
fn has_import_link(report: &ChangeReport) -> bool {
    report.edges.iter().any(|e| e.from == "folder:app" && e.to == "folder:lib" && e.refs.iter().any(|r| r.symbol == "import lib.Format"))
}

/// What a syntax-only report of `two_callers` shows: the imports and no call, and none of the checks that need
/// every reference.
fn assert_syntax_only(report: &ChangeReport) {
    assert_eq!(report.analysis.stage, "complete");
    assert_eq!(report.analyzer.resolution, "syntax");
    let coverage = &report.analysis.languages[0];
    assert_eq!(coverage.resolution, "syntax");
    assert_eq!(coverage.held_back, ["unused-api", "orphaned", "untested", "conformers"]);
    assert!(!has_call_link(report), "no call is linked by name: {:?}", report.edges);
    assert!(has_import_link(report), "the import still links the components: {:?}", report.edges);
    assert!(report.review_items.iter().all(|i| i.used_by.is_empty()), "no use is found by name");
    assert!(findings(report, "orphaned").is_empty() && findings(report, "unused-api").is_empty(), "{:?}", report.findings);
}

fn side_index(files: &[(&str, Vec<IndexedRef>)]) -> SideIndex {
    SideIndex { refs: files.iter().map(|(f, r)| (f.to_string(), r.clone())).collect(), warnings: Vec::new() }
}

/// The index's record of a call of `Format.legacy` at line 6 of the file it is listed under.
fn legacy_call() -> IndexedRef {
    IndexedRef { line: 6, target_file: "lib/Format.kt".to_string(), target_line: 4, name: "legacy".to_string() }
}

#[test]
fn core_003_a_failed_index_leaves_a_syntax_only_report_with_a_warning() {
    // No Bazel workspace, so no index can be built: the review ends syntax-only.
    let repo = two_callers();
    let report = analyze(request(&repo));
    assert_syntax_only(&report);
    let warnings = index_warnings(&report);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, "index-unavailable");
    assert!(warnings[0].message.contains("Kotlin") && warnings[0].message.contains("Bazel workspace"), "the warning names the language and the reason: {}", warnings[0].message);
    assert!(report.analysis.languages[0].note.as_deref().unwrap_or("").contains("Bazel workspace"), "{:?}", report.analysis.languages);
}

#[test]
fn core_003_cancelled_indexing_leaves_a_syntax_only_report_with_a_warning() {
    let repo = two_callers();
    let mut session = open(request(&repo));
    let report = session.finish_cancelled();
    assert_syntax_only(&report);
    let warnings = index_warnings(&report);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert!(warnings[0].kind == "index-unavailable" && warnings[0].message.contains("Kotlin") && warnings[0].message.contains("cancelled"), "{warnings:?}");
}

#[test]
fn core_003_files_the_index_misses_are_syntax_only_and_listed() {
    let repo = two_callers();
    // app/App.kt is missing at both sides, as if its target had not been built.
    let mut session = open(request(&repo));
    session.set_index(
        "kotlin",
        side_index(&[("lib/Format.kt", vec![]), ("other/Other.kt", vec![legacy_call()])]),
        side_index(&[("lib/Format.kt", vec![]), ("other/Other.kt", vec![])]),
    );
    let report = session.report();
    assert_eq!(report.analyzer.resolution, "index");
    let coverage = &report.analysis.languages[0];
    assert_eq!((coverage.files, coverage.indexed_files), (3, 2));
    let warnings = index_warnings(&report);
    assert!(!warnings.is_empty());
    for w in &warnings {
        assert!(w.kind == "index-partial" && w.message.contains("Kotlin") && w.message.contains("app/App.kt"), "{w:?}");
    }
    assert!(!has_call_link(&report), "the uncovered file's call is not matched by name");
    assert!(has_import_link(&report), "its import still links it");
    // app/App.kt may still call Format.legacy, so the check that would say the change removed the last
    // caller does not run, and the report says so.
    assert!(findings(&report, "orphaned").is_empty(), "{:?}", findings(&report, "orphaned"));
    assert_eq!(coverage.held_back, ["unused-api", "orphaned"]);
    let held = held_back_warnings(&report);
    assert!(held.len() == 1 && held[0].message.contains("orphaned") && held[0].message.contains("1 of 3"), "{held:?}");

    // The same change with an index that covers app/App.kt and has no call in it: the index is believed,
    // no warning is needed, and the removed call in other/Other.kt was the last one.
    let mut session = open(request(&repo));
    session.set_index(
        "kotlin",
        side_index(&[("lib/Format.kt", vec![]), ("app/App.kt", vec![]), ("other/Other.kt", vec![legacy_call()])]),
        side_index(&[("lib/Format.kt", vec![]), ("app/App.kt", vec![]), ("other/Other.kt", vec![])]),
    );
    let report = session.report();
    assert!(index_warnings(&report).is_empty() && held_back_warnings(&report).is_empty(), "{:?}", report.warnings);
    assert!(report.analysis.languages[0].held_back.is_empty());
    assert!(!has_call_link(&report));
    assert_eq!(findings(&report, "orphaned").len(), 1, "{:?}", report.findings);
}

/// A file the index has at head but not at base is resolved through neither: different coverage of the two
/// sides must not show up as an added call, and the file is not matched by name either.
#[test]
fn core_003_a_file_covered_at_one_side_only_is_syntax_only_and_listed() {
    let repo = two_callers();
    let mut session = open(request(&repo));
    session.set_index(
        "kotlin",
        side_index(&[("lib/Format.kt", vec![]), ("other/Other.kt", vec![legacy_call()])]),
        side_index(&[("lib/Format.kt", vec![]), ("app/App.kt", vec![legacy_call()]), ("other/Other.kt", vec![])]),
    );
    let report = session.report();
    assert!(!has_call_link(&report), "the head-only index data is not used: {:?}", report.edges);
    assert!(has_import_link(&report));
    assert_eq!((report.analysis.languages[0].files, report.analysis.languages[0].indexed_files), (3, 2));
    let partial: Vec<&Warning> = index_warnings(&report).into_iter().filter(|w| w.kind == "index-partial").collect();
    assert_eq!(partial.len(), 2, "listed at both sides: {partial:?}");
    assert!(partial.iter().all(|w| w.message.contains("app/App.kt") && w.message.contains("only at one side")), "{partial:?}");
}

/// A new public function whose only caller sits in a file the index misses: the missing coverage is not
/// taken as evidence that nothing calls it.
#[test]
fn core_003_unused_api_is_held_back_when_a_caller_could_be_outside_the_index() {
    let repo = two_commits(
        &[("lib/Api.kt", "package lib\n\nclass Api\n"), ("app/App.kt", "package app\n\nfun main() {\n}\n")],
        &[
            ("lib/Api.kt", Some("package lib\n\nclass Api {\n    fun fresh(): Int = 1\n}\n")),
            ("app/App.kt", Some("package app\n\nimport lib.Api\n\nfun main() {\n    Api().fresh()\n}\n")),
        ],
    );
    let fresh_call = IndexedRef { line: 6, target_file: "lib/Api.kt".to_string(), target_line: 4, name: "fresh".to_string() };
    let only_lib = || side_index(&[("lib/Api.kt", vec![])]);

    let mut session = open(request(&repo));
    session.set_index("kotlin", only_lib(), only_lib());
    let report = session.report();
    assert!(findings(&report, "unused-api").is_empty(), "{:?}", report.findings);
    assert!(held_back_warnings(&report).iter().any(|w| w.message.contains("unused-api")), "{:?}", report.warnings);

    // With app/App.kt indexed, its call is a use; without the call, the function is unused.
    let mut session = open(request(&repo));
    session.set_index("kotlin", side_index(&[("lib/Api.kt", vec![]), ("app/App.kt", vec![])]), side_index(&[("lib/Api.kt", vec![]), ("app/App.kt", vec![fresh_call])]));
    assert!(findings(&session.report(), "unused-api").is_empty());
    let mut session = open(request(&repo));
    session.set_index("kotlin", side_index(&[("lib/Api.kt", vec![]), ("app/App.kt", vec![])]), side_index(&[("lib/Api.kt", vec![]), ("app/App.kt", vec![])]));
    assert_eq!(findings(&session.report(), "unused-api").len(), 1, "the index covers every file and records no caller");
}

/// The review scope often builds no test targets. Then the index can't say that no test references a changed
/// function, so `untested` is held back while the checks that need only non-test files still run.
#[test]
fn core_003_untested_is_held_back_when_tests_are_outside_the_index() {
    let repo = two_commits(
        &[
            ("store/Store.kt", "package store\n\nclass Store {\n    fun load(): Int = 1\n}\n"),
            ("tests/StoreTest.kt", "package tests\n\nimport store.Store\n\nfun testStore() {\n    Store()\n}\n"),
        ],
        &[("store/Store.kt", Some("package store\n\nclass Store {\n    fun load(): Int = 2\n}\n"))],
    );
    let store = || side_index(&[("store/Store.kt", vec![])]);
    let mut session = open(request(&repo));
    session.set_index("kotlin", store(), store());
    let report = session.report();
    assert!(findings(&report, "untested").is_empty(), "{:?}", report.findings);
    assert_eq!(report.analysis.languages[0].held_back, ["untested"]);
    let held = held_back_warnings(&report);
    assert!(held.len() == 1 && held[0].message.contains("untested") && held[0].message.contains("1 of 1 Kotlin test files"), "{held:?}");
    assert!(index_warnings(&report).is_empty(), "test files are not listed as missing: {:?}", report.warnings);

    // With the test file indexed and not calling load(), the change is untested.
    let mut session = open(request(&repo));
    let with_test = || side_index(&[("store/Store.kt", vec![]), ("tests/StoreTest.kt", vec![IndexedRef { line: 6, target_file: "store/Store.kt".to_string(), target_line: 3, name: "Store".to_string() }])]);
    session.set_index("kotlin", with_test(), with_test());
    let report = session.report();
    assert_eq!(findings(&report, "untested").len(), 1, "{:?}", report.findings);
    assert!(report.analysis.languages[0].held_back.is_empty());
}

#[test]
fn core_003_with_indexes_off_the_report_is_syntax_only_with_a_warning() {
    let repo = two_callers();
    let mut request = request(&repo);
    request.index = Some(false);
    let report = analyze(request);
    assert_syntax_only(&report);
    let warnings = index_warnings(&report);
    assert!(warnings.len() == 1 && warnings[0].kind == "index-unavailable" && warnings[0].message.contains("turned off"), "{warnings:?}");
}

/// The comparison report is the one place where references are matched by name, and it says so.
#[test]
fn core_003_only_the_comparison_report_matches_by_name() {
    let repo = two_callers();
    let (session, reports, _) = run(request(&repo));
    assert!(reports.iter().all(|r| !has_call_link(r)), "no report of the review matches by name");
    let named = session.name_based_report();
    assert_eq!(named.analysis.variant, "name-based");
    assert_eq!(named.analyzer.resolution, "name-based");
    assert_eq!(named.analysis.languages[0].resolution, "name-based");
    assert!(has_call_link(&named), "the comparison report matches the call by name");
    assert!(index_warnings(&named).is_empty() && held_back_warnings(&named).is_empty(), "{:?}", named.warnings);
}

/// The first view, before any index: nothing is matched by name, no index warning is given yet because the
/// index is still to come, and the conclusions that need every reference are held back.
#[test]
fn the_preliminary_report_matches_nothing_by_name() {
    let repo = two_callers();
    let report = open(request(&repo)).report();
    assert_eq!(report.analysis.stage, "preliminary");
    assert_eq!(report.analyzer.resolution, "preliminary");
    assert_eq!(report.analysis.languages[0].resolution, "preliminary");
    assert!(report.analysis.languages[0].held_back.is_empty(), "nothing is final yet");
    assert!(!has_call_link(&report), "a call is not a link that syntax proves");
    assert!(
        report.edges.iter().any(|e| e.from == "folder:app" && e.to == "folder:lib" && e.refs.iter().all(|r| r.symbol.starts_with("import "))),
        "the import still links the components: {:?}",
        report.edges
    );
    assert!(index_warnings(&report).is_empty(), "{:?}", report.warnings);
    assert!(findings(&report, "orphaned").is_empty() && findings(&report, "unused-api").is_empty(), "{:?}", report.findings);
}

// MARK: CORE-004 A failed LLM reply keeps the deterministic report

/// Two components that change, and lib now imports app, which closes a cycle: a deterministic finding the
/// LLM's reply must not take away.
fn llm_change() -> TestRepo {
    two_commits(
        &[
            ("lib/Cart.kt", "package lib\n\nclass Cart {\n    val items = mutableListOf<Int>()\n\n    fun total(): Int {\n        return 1\n    }\n}\n"),
            ("app/App.kt", "package app\n\nimport lib.Cart\n\nfun show() {\n    println(Cart().total())\n}\n"),
        ],
        &[
            (
                "lib/Cart.kt",
                Some("package lib\n\nimport app.show\n\nclass Cart {\n    val items = mutableListOf<Int>()\n\n    fun total(): Int {\n        return items.sum()\n    }\n}\n"),
            ),
            ("app/App.kt", Some("package app\n\nimport lib.Cart\n\nfun show() {\n    println(Cart().total() + 1)\n}\n")),
        ],
    )
}

fn llm_warnings<'r>(report: &'r ChangeReport, kind: &str) -> Vec<&'r Warning> {
    report.warnings.iter().filter(|w| w.kind == kind).collect()
}

/// Every region keeps its deterministic risk, and the deterministic findings are all still there.
fn assert_deterministic_kept(before: &ChangeReport, after: &ChangeReport) {
    assert_eq!(without_llm(after), *before, "the pass adds to the report and changes nothing else");
    let risks = |r: &ChangeReport| r.regions.iter().map(|g| (g.id.clone(), g.risk)).collect::<Vec<_>>();
    assert_eq!(risks(after), risks(before));
    let checks = |r: &ChangeReport| r.findings.iter().filter(|f| f.source == "check").cloned().collect::<Vec<_>>();
    assert_eq!(checks(after), checks(before));
}

#[test]
fn core_004_a_rejected_batch_leaves_the_other_batches_and_every_deterministic_score() {
    let repo = llm_change();
    let dir = tempfile::tempdir().unwrap();
    // lib's batch gets a risk outside 0…1 on every attempt; app's batch and the structural review are fine.
    let wrapper = fake_llm_wrapper(dir.path(), "lib-invalid", "ok", Some(("^## Component lib ", "invalid")));
    let (before, after) = run_with_llm(request(&repo), llm_options(&wrapper, &dir.path().join("cache")));
    assert_deterministic_kept(&before, &after);
    let run = after.llm.as_ref().expect("the pass ran");
    assert_eq!((run.batches, run.failed, run.review.as_deref()), (2, 1, Some("ok")));
    let rejected = llm_warnings(&after, "llm-rejected");
    assert_eq!(rejected.len(), 1, "{:?}", after.warnings);
    assert!(rejected[0].message.contains("LLM reply for lib failed validation") && rejected[0].message.contains("outside 0...1"), "{}", rejected[0].message);
    for e in &after.review_items {
        assert_eq!(e.llm.is_some(), e.component == "folder:app", "{}: only app's batch was accepted", e.id);
    }
    for g in &after.regions {
        assert_eq!(g.llm.is_some(), g.review_item.starts_with("app/"), "{}", g.id);
    }
    assert!(after.findings.iter().any(|f| f.source == "llm"), "the structural review was accepted");
}

#[test]
fn core_004_a_rejected_structural_review_adds_no_findings_and_keeps_the_deterministic_ones() {
    let repo = llm_change();
    let dir = tempfile::tempdir().unwrap();
    // The structural review answers with an unknown kind on every attempt; the batches are fine.
    let wrapper = fake_llm_wrapper(dir.path(), "review-invalid", "ok", Some(("^You are reviewing the structure", "invalid")));
    let (before, after) = run_with_llm(request(&repo), llm_options(&wrapper, &dir.path().join("cache")));
    assert!(kinds(&before).contains("cycle"), "a deterministic finding to keep: {:?}", kinds(&before));
    assert_deterministic_kept(&before, &after);
    let run = after.llm.as_ref().expect("the pass ran");
    assert_eq!((run.failed, run.review.as_deref()), (0, Some("rejected")), "a rejected review counts in llm.review, not llm.failed");
    assert!(after.findings.iter().all(|f| f.source == "check"));
    let rejected = llm_warnings(&after, "llm-rejected");
    assert_eq!(rejected.len(), 1);
    assert!(rejected[0].message.starts_with("LLM structural review failed validation"), "{}", rejected[0].message);
    assert!(after.review_items.iter().all(|e| e.llm.is_some()), "the batches' summaries stay");
}

#[test]
fn core_004_a_failing_cli_keeps_the_deterministic_report() {
    let repo = llm_change();
    let dir = tempfile::tempdir().unwrap();
    // fail: the CLI exits with an error; error: claude's is_error result; invalid: every reply is out of range.
    for mode in ["fail", "error", "invalid"] {
        let wrapper = fake_llm_wrapper(dir.path(), &format!("{mode}-llm"), mode, None);
        let (before, after) = run_with_llm(request(&repo), llm_options(&wrapper, &dir.path().join(format!("cache-{mode}"))));
        assert_deterministic_kept(&before, &after);
        let run = after.llm.as_ref().expect("the pass ran");
        assert_eq!((run.failed, run.batches, run.review.as_deref()), (2, 2, Some("rejected")), "{mode}");
        assert_eq!(llm_warnings(&after, "llm-rejected").len(), 3, "{mode}: two batches and the review");
        assert!(after.review_items.iter().all(|e| e.llm.is_none()) && after.regions.iter().all(|g| g.llm.is_none()), "{mode}");
        assert!(after.findings.iter().all(|f| f.source == "check"), "{mode}");
    }
}

#[test]
fn core_004_a_missing_cli_leaves_the_report_as_without_the_llm() {
    let repo = llm_change();
    let dir = tempfile::tempdir().unwrap();
    let (before, after) = run_with_llm(request(&repo), llm_options(std::path::Path::new("/nonexistent/fake-llm"), dir.path()));
    let mut expected = before.clone();
    expected.warnings.push(llm_warnings(&after, "llm-unavailable").first().map(|w| (*w).clone()).expect("an llm-unavailable warning"));
    assert_eq!(after, expected, "the same report, plus one llm-unavailable warning");
    assert_eq!(after.llm, None);
}

// MARK: CORE-005 Every finding points at something on the map

/// Every finding of a report cites evidence and points at something the report has.
fn assert_anchored(report: &ChangeReport) {
    let components: BTreeSet<&str> = report.components.iter().map(|c| c.id.as_str()).collect();
    let review_items: BTreeSet<&str> = report.review_items.iter().map(|i| i.id.as_str()).collect();
    let edges: BTreeSet<(&str, &str)> = report.edges.iter().map(|e| (e.from.as_str(), e.to.as_str())).collect();
    for f in &report.findings {
        assert!(!f.evidence.is_empty(), "{} cites no evidence", f.id);
        assert!(!f.anchors.is_empty(), "{} has no anchor", f.id);
        for a in &f.anchors {
            if let Some(id) = &a.review_item {
                assert!(review_items.contains(id.as_str()), "{}: unknown review item {id}", f.id);
            } else if let Some(id) = &a.component {
                assert!(components.contains(id.as_str()), "{}: unknown component {id}", f.id);
            } else if let (Some(from), Some(to)) = (&a.from, &a.to) {
                assert!(edges.contains(&(from.as_str(), to.as_str())), "{}: no dependency {from} -> {to}", f.id);
            } else {
                panic!("{}: an anchor names nothing", f.id);
            }
        }
    }
}

fn kinds(report: &ChangeReport) -> BTreeSet<&str> {
    report.findings.iter().map(|f| f.kind.as_str()).collect()
}

#[test]
fn core_005_every_finding_is_anchored_in_the_report() {
    // Head adds a public function nobody calls and a reference from store back to app, which closes a cycle.
    let repo = two_commits(
        &[
            ("app/App.kt", "package app\n\nimport store.Store\n\nclass AppRoot {\n    val store = Store()\n}\n"),
            ("store/Store.kt", "package store\n\nclass Store {\n    internal fun load() {}\n}\n"),
            ("tests/StoreTest.kt", "package tests\n\nimport store.Store\n\nfun testStore() {\n    Store()\n}\n"),
        ],
        &[("store/Store.kt", Some("package store\n\nimport app.AppRoot\n\nclass Store {\n    internal fun load() {}\n    fun nobody() {}\n    fun root(): AppRoot? = null\n}\n"))],
    );
    // An index that covers every file, tests included, so every check runs.
    let to = |line: u32, file: &str, target_line: u32, name: &str| IndexedRef { line, target_file: file.to_string(), target_line, name: name.to_string() };
    let mut session = open(request(&repo));
    session.set_index(
        "kotlin",
        side_index(&[
            ("app/App.kt", vec![to(6, "store/Store.kt", 3, "Store")]),
            ("store/Store.kt", vec![]),
            ("tests/StoreTest.kt", vec![to(6, "store/Store.kt", 3, "Store")]),
        ]),
        side_index(&[
            ("app/App.kt", vec![to(6, "store/Store.kt", 5, "Store")]),
            ("store/Store.kt", vec![to(8, "app/App.kt", 5, "AppRoot")]),
            ("tests/StoreTest.kt", vec![to(6, "store/Store.kt", 5, "Store")]),
        ]),
    );
    let report = session.report();
    assert!(kinds(&report).is_superset(&BTreeSet::from(["cycle", "unused-api", "untested"])), "the checks found {:?}", kinds(&report));
    assert_anchored(&report);

    // The comparison report, which matches by name, and the review's own final report, which is syntax-only.
    let named = session.name_based_report();
    assert!(kinds(&named).is_superset(&BTreeSet::from(["cycle", "unused-api", "untested"])), "the checks found {:?}", kinds(&named));
    assert_anchored(&named);
    let syntax_only = analyze(request(&repo));
    assert!(kinds(&syntax_only).contains("cycle"), "the imports close the cycle: {:?}", kinds(&syntax_only));
    assert_anchored(&syntax_only);
}

#[test]
fn core_005_an_llm_finding_without_a_known_anchor_is_rejected() {
    let repo = llm_change();
    let dir = tempfile::tempdir().unwrap();
    // The structural review names an unknown component, an unknown review item, an edge that isn't there, and
    // nothing at all; the batches go to the fake.
    let reply = r#"{"findings": [
{"kind": "missing", "severity": "high", "message": "No test.", "evidence": ["None."], "anchors": [{"component": "folder:nowhere"}]},
{"kind": "missing", "severity": "high", "message": "No test.", "evidence": ["None."], "anchors": [{"reviewItem": "lib/Cart.kt::Gone"}]},
{"kind": "placement", "severity": "low", "message": "Odd edge.", "evidence": ["None."], "anchors": [{"from": "folder:app", "to": "folder:nowhere"}]},
{"kind": "intent", "severity": "low", "message": "Unclear.", "evidence": ["None."], "anchors": []}
]}"#;
    let script = dir.path().join("bad-anchors");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\nprompt=$(cat)\ncase \"$prompt\" in\n  'You are reviewing the structure'*) cat <<'EOF'\n{reply}\nEOF\n  ;;\n  *) printf '%s\\n' \"$prompt\" | '{}' \"$@\" ;;\nesac\n",
            fake_llm().display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let (_, after) = run_with_llm(request(&repo), llm_options(&script, &dir.path().join("cache")));
    assert_eq!(after.llm.as_ref().and_then(|r| r.review.as_deref()), Some("rejected"));
    let rejected = llm_warnings(&after, "llm-rejected");
    assert_eq!(rejected.len(), 1, "{:?}", after.warnings);
    for part in ["unknown component folder:nowhere", "unknown review item lib/Cart.kt::Gone", "no edge folder:app → folder:nowhere", "finding 4 has no anchor"] {
        assert!(rejected[0].message.contains(part), "{part} in {}", rejected[0].message);
    }
    assert!(after.findings.iter().all(|f| f.source == "check"));
    assert_anchored(&after);
}

// MARK: CORE-006 Formatting-only changes ask for no review

#[test]
fn core_006_a_cosmetic_review_item_asks_for_no_review() {
    // title() is only reformatted; count() really changes.
    let repo = two_commits(
        &[("lib/View.kt", "package lib\n\nclass CatalogView {\n    fun title(): String {\n        return \"Catalog\"\n    }\n\n    fun count(): Int = 1\n}\n")],
        &[("lib/View.kt", Some("package lib\n\nclass CatalogView {\n    fun title(): String { return \"Catalog\" }\n\n    fun count(): Int = 2\n}\n"))],
    );
    let report = analyze(request(&repo));
    let cosmetic = review_item(&report, "CatalogView.title()");
    assert_eq!(cosmetic.change, ChangeKind::Cosmetic, "it stays in the report");
    assert_eq!(review_item(&report, "CatalogView.count()").change, ChangeKind::Body);
    assert!(!report.regions.iter().any(|r| r.review_item == cosmetic.id), "no regions");
    assert!(!report.findings.iter().any(|f| f.anchors.iter().any(|a| a.review_item.as_deref() == Some(cosmetic.id.as_str()))), "no findings");
    let component = report.components.iter().find(|c| c.id == cosmetic.component).expect("its component");
    assert_eq!(component.changed_review_items, 1, "only count() is counted as changed");
    // The container is judged member by member and is never cosmetic itself.
    assert!(!report.review_items.iter().any(|i| i.qualified_name == "CatalogView" && i.change == ChangeKind::Cosmetic));
}

#[test]
fn core_006_a_commit_that_only_reformats_adds_nothing_to_review() {
    let repo = two_commits(
        &[("lib/View.kt", "package lib\n\nclass CatalogView {\n    fun title(): String {\n        return \"Catalog\"\n    }\n}\n")],
        &[("lib/View.kt", Some("package lib\n\nclass CatalogView {\n    fun title(): String { return \"Catalog\" }\n}\n"))],
    );
    let report = analyze(request(&repo));
    assert_eq!(changes(&report).get("CatalogView.title()"), Some(&ChangeKind::Cosmetic));
    assert!(report.regions.is_empty(), "{:?}", report.regions);
    assert!(report.findings.is_empty(), "{:?}", report.findings);
    assert!(report.components.iter().all(|c| c.changed_review_items == 0), "{:?}", report.components);
}
