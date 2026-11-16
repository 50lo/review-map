//! The LLM pass (`reviewmap_core::llm`) from start to end, with `scripts/fake-llm.sh` standing in for
//! `claude` and `codex`: no test here runs a real coding agent. The fake fills the reply template of each
//! annotation prompt with values picked by a hash of each id, and answers the structural review with one
//! finding on the first component it lists. CORE-004, what a failed reply leaves, is in `core_rules.rs`.
//!
//! Each test runs a fake of its own, a wrapper in its own temporary directory: replies are cached by command,
//! among the rest, so no test reads replies that another test cached.

mod common;

use common::*;
use reviewmap_core::model::ChangeReport;
use reviewmap_core::proc::Cancel;
use reviewmap_core::session::{self, Event};
use std::collections::BTreeMap;

/// Two components: lib's `Cart.total` changes and `Cart.add` is new, and app calls `add` instead of `total`.
/// Cart's stored properties are context for both of Cart's changed functions.
fn cart_change() -> TestRepo {
    let state = "    val items = mutableListOf<Int>()\n    var rate = 0\n";
    two_commits(
        &[
            ("lib/Cart.kt", &format!("package lib\n\nclass Cart {{\n{state}\n    fun total(): Int {{\n        return 1\n    }}\n}}\n")),
            ("app/App.kt", "package app\n\nimport lib.Cart\n\nfun show() {\n    println(Cart().total())\n}\n"),
        ],
        &[
            (
                "lib/Cart.kt",
                Some(&format!(
                    "package lib\n\nclass Cart {{\n{state}\n    fun total(): Int {{\n        return items.sum() * rate\n    }}\n\n    fun add(n: Int): Int {{\n        items.add(n)\n        return total()\n    }}\n}}\n"
                )),
            ),
            ("app/App.kt", Some("package app\n\nimport lib.Cart\n\nfun show() {\n    val cart = Cart()\n    println(cart.add(1))\n}\n")),
        ],
    )
}

/// Review items the LLM annotates: not cosmetic, test, or generated, outside test components.
fn eligible(report: &ChangeReport) -> Vec<&reviewmap_core::model::ReviewItem> {
    report
        .review_items
        .iter()
        .filter(|e| e.change != reviewmap_core::model::ChangeKind::Cosmetic && !e.tags.iter().any(|t| t == "test" || t == "generated"))
        .collect()
}

/// What every annotated report of `cart_change` has: a summary for each eligible review item and each
/// component with one, a risk in 0…1 for every review and removed region, keep for every context region, and
/// the structural review's finding.
fn assert_annotated(report: &ChangeReport) {
    let items = eligible(report);
    assert!(!items.is_empty());
    for e in &items {
        let summary = &e.llm.as_ref().unwrap_or_else(|| panic!("{} has no summary", e.id)).summary;
        assert!(!summary.is_empty() && !summary.contains('\n'));
    }
    for c in report.components.iter().filter(|c| items.iter().any(|e| e.component == c.id)) {
        assert!(c.llm.is_some(), "{} has no summary", c.id);
    }
    let ids: Vec<&str> = items.iter().map(|e| e.id.as_str()).collect();
    for g in report.regions.iter().filter(|g| ids.contains(&g.review_item.as_str())) {
        let llm = g.llm.as_ref().unwrap_or_else(|| panic!("{} has no LLM annotation", g.id));
        if g.kind == "context" {
            assert!(llm.keep.is_some() && llm.risk.is_none(), "{}: {llm:?}", g.id);
        } else {
            let risk = llm.risk.unwrap_or_else(|| panic!("{} has no risk", g.id));
            assert!((0.0..=1.0).contains(&risk), "{}: {risk}", g.id);
        }
    }
    let found: Vec<_> = report.findings.iter().filter(|f| f.source == "llm").collect();
    assert_eq!(found.len(), 1, "the fake's one finding");
    assert_eq!((found[0].id.as_str(), found[0].kind.as_str(), found[0].severity.as_str()), ("complexity:1", "complexity", "medium"));
    let anchor = found[0].anchors[0].component.as_deref().expect("a component anchor");
    assert!(report.components.iter().any(|c| c.id == anchor));
    assert!(report.warnings.iter().all(|w| !w.kind.starts_with("llm-")), "{:?}", report.warnings);
}

/// A fake of the test's own, in `dir`.
fn own_fake(dir: &tempfile::TempDir) -> std::path::PathBuf {
    fake_llm_wrapper(dir.path(), "fake-llm", "ok", None)
}

#[test]
fn annotates_a_review_with_the_fake_as_claude() {
    let repo = cart_change();
    let dir = tempfile::tempdir().unwrap();
    let (before, after) = run_with_llm(request(&repo), llm_options(&own_fake(&dir)));
    assert_annotated(&after);
    assert_eq!(without_llm(&after), before, "the pass adds to the report and changes nothing else");
    let run = after.llm.as_ref().expect("the run");
    assert_eq!((run.tool.as_str(), run.command.as_deref(), run.prompt_version.as_str()), ("claude", Some("fake-llm"), "3"));
    assert_eq!((run.cached, run.failed), (0, 0));
    assert_eq!(run.batches, 2, "one per component");
    assert_eq!((run.review.as_deref(), run.description.as_deref(), run.review_notes), (Some("ok"), Some("commits"), false));
    assert_eq!(before.llm, None);
}

#[test]
fn annotates_a_review_with_the_fake_as_codex() {
    let repo = cart_change();
    let dir = tempfile::tempdir().unwrap();
    let mut options = llm_options(&own_fake(&dir));
    options.tool = "codex".to_string();
    let (_, after) = run_with_llm(request(&repo), options);
    assert_annotated(&after);
    assert_eq!(after.llm.as_ref().unwrap().tool, "codex");
}

#[test]
fn kept_context_is_ranked_from_one() {
    let repo = cart_change();
    let dir = tempfile::tempdir().unwrap();
    let (_, after) = run_with_llm(request(&repo), llm_options(&own_fake(&dir)));
    let mut ranks: BTreeMap<&str, Vec<u32>> = BTreeMap::new();
    for g in after.regions.iter().filter(|g| g.kind == "context") {
        let llm = g.llm.as_ref().expect("an annotation");
        match llm.keep {
            Some(true) => ranks.entry(g.review_item.as_str()).or_default().push(llm.rank.expect("a kept region's rank")),
            _ => assert_eq!(llm.rank, None),
        }
    }
    assert_eq!(after.regions.iter().filter(|g| g.kind == "context").count(), 2, "Cart's state, for total and add");
    assert!(!ranks.is_empty(), "the fake keeps some context");
    for (item, mut r) in ranks {
        r.sort();
        assert_eq!(r, (1..=r.len() as u32).collect::<Vec<_>>(), "{item}");
    }
}

#[test]
fn a_reply_wrapped_in_prose_is_accepted() {
    let repo = cart_change();
    let dir = tempfile::tempdir().unwrap();
    let prose = fake_llm_wrapper(dir.path(), "prose-llm", "prose", None);
    let (_, after) = run_with_llm(request(&repo), llm_options(&prose));
    assert_annotated(&after);
}

#[test]
fn a_second_review_of_the_same_change_comes_from_the_cache() {
    let repo = cart_change();
    let dir = tempfile::tempdir().unwrap();
    let fake = own_fake(&dir);
    let (_, first) = run_with_llm(request(&repo), llm_options(&fake));
    let calls = fake_llm_calls(&fake);
    assert_eq!(calls, 3, "two batches and the structural review");
    let (_, second) = run_with_llm(request(&repo), llm_options(&fake));
    assert_eq!(fake_llm_calls(&fake), calls, "the second review runs the CLI no more");
    assert_annotated(&second);
    let run = second.llm.as_ref().unwrap();
    assert_eq!((run.batches, run.cached, run.review.as_deref()), (2, 2, Some("cached")));
    assert_eq!(without_run(&second), without_run(&first), "the same annotations");
}

#[test]
fn another_command_does_not_read_the_cached_replies() {
    let repo = cart_change();
    let (one, two) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    run_with_llm(request(&repo), llm_options(&own_fake(&one)));
    let other = own_fake(&two);
    let (_, after) = run_with_llm(request(&repo), llm_options(&other));
    assert_eq!(fake_llm_calls(&other), 3, "nothing came from the first command's replies");
    assert_eq!(after.llm.as_ref().unwrap().cached, 0);
}

fn without_run(report: &ChangeReport) -> ChangeReport {
    let mut r = report.clone();
    r.llm = None;
    r
}

#[test]
fn the_prompts_carry_the_description_and_the_review_notes() {
    let repo = cart_change();
    repo.write("REVIEW.md", "Watch the cart's totals.\n");
    repo.commit("Add review notes\n\nThe cart's totals matter most.");
    let dir = tempfile::tempdir().unwrap();
    let prompts = dir.path().join("prompts");
    std::fs::create_dir_all(&prompts).unwrap();
    // Keeps every prompt, then answers like the fake.
    let recorder = dir.path().join("recording-llm");
    std::fs::write(
        &recorder,
        format!("#!/bin/sh\nf=$(mktemp '{}/prompt.XXXXXX')\ncat > \"$f\"\nexec '{}' \"$@\" < \"$f\"\n", prompts.display(), fake_llm().display()),
    )
    .unwrap();
    std::fs::set_permissions(&recorder, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let (_, after) = run_with_llm(request(&repo), llm_options(&recorder));
    let texts: Vec<String> = std::fs::read_dir(&prompts).unwrap().flatten().map(|e| std::fs::read_to_string(e.path()).unwrap()).collect();
    let review: Vec<&String> = texts.iter().filter(|t| t.starts_with("You are reviewing the structure")).collect();
    assert_eq!(review.len(), 1);
    assert!(review[0].contains("<description source=\"commit messages\">"));
    assert!(review[0].contains("The cart's totals matter most."));
    assert!(review[0].contains("## Components\n- folder:"), "the fake reads the first component from here");
    let annotation: Vec<&String> = texts.iter().filter(|t| t.contains("<reply-template>")).collect();
    assert_eq!(annotation.len(), 2);
    for t in texts.iter() {
        assert!(t.contains("<review-notes>") && t.contains("Watch the cart's totals."));
    }
    let run = after.llm.as_ref().unwrap();
    assert!(run.review_notes);
    assert_eq!(run.description.as_deref(), Some("commits"));
}

#[test]
fn cancelling_stops_the_cli_and_keeps_the_final_report() {
    let repo = cart_change();
    let dir = tempfile::tempdir().unwrap();
    let slow = dir.path().join("slow-llm");
    std::fs::write(&slow, "#!/bin/sh\nsleep 60\n").unwrap();
    std::fs::set_permissions(&slow, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let mut req = request(&repo);
    req.llm = Some(llm_options(&slow));
    home(None);
    let cancel = Cancel::new();
    let reports = std::sync::Mutex::new(Vec::new());
    let started = std::time::Instant::now();
    // Cancels half a second after the LLM pass starts, while the CLI runs.
    let emit = |event: Event| match event {
        Event::Report(r) => reports.lock().unwrap().push(*r),
        Event::Progress(p) if p.starts_with("LLM: ") && p.contains("to run with") => {
            let later = cancel.clone();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(500));
                later.cancel();
            });
        }
        Event::Progress(_) => {}
    };
    session::run(req, &cancel, &emit).expect("the review ends");
    assert!(cancel.is_cancelled());
    assert!(started.elapsed() < std::time::Duration::from_secs(30), "the CLI was stopped");
    let reports = reports.into_inner().unwrap();
    let last = reports.last().expect("a report");
    assert_eq!(last.analysis.stage, "complete");
    assert_eq!(last.llm, None, "no report after the cancelled pass");
}

#[test]
fn without_llm_options_no_llm_runs() {
    let repo = cart_change();
    let (_, reports, progress) = run(request(&repo));
    assert!(reports.iter().all(|r| r.llm.is_none() && r.review_items.iter().all(|e| e.llm.is_none())));
    assert!(progress.iter().all(|p| !p.starts_with("LLM")));
}

#[test]
fn reads_sources_from_the_commits() {
    // The working tree differs from the head commit; the prompts show the commit.
    let repo = cart_change();
    repo.write("lib/Cart.kt", "package lib\n\nclass Uncommitted\n");
    let dir = tempfile::tempdir().unwrap();
    let prompts = dir.path().join("prompt.txt");
    let recorder = dir.path().join("recording-llm");
    std::fs::write(&recorder, format!("#!/bin/sh\ntee -a '{}' | '{}' \"$@\"\n", prompts.display(), fake_llm().display())).unwrap();
    std::fs::set_permissions(&recorder, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    run_with_llm(request(&repo), llm_options(&recorder));
    let text = std::fs::read_to_string(&prompts).unwrap();
    assert!(text.contains("fun add(n: Int): Int {"));
    assert!(!text.contains("Uncommitted"));
}
