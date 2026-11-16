//! What the acceptance tests share: small git repositories built with `git`, a private `REVIEWMAP_HOME`,
//! and the analysis of a change from start to its final report.
#![allow(dead_code)]

use reviewmap_core::model::{ChangeKind, ChangeReport, Finding, ReviewItem};
use reviewmap_core::proc::Cancel;
use reviewmap_core::session::{self, Event, ReviewRequest, Session};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

/// The checkout these tests run from. Under `bazel test` they run in their runfiles, where the files a test
/// declares as `data` are linked; this file is one of them, and its link leads back to the checkout. A test
/// that reads the checkout itself (the Bazel fixtures, which `.bazelignore` keeps out of Bazel's view, and the
/// kept test home) is therefore tagged to run outside the sandbox. Under Cargo it is the manifest's directory,
/// two levels up.
pub fn checkout() -> &'static Path {
    static CHECKOUT: OnceLock<PathBuf> = OnceLock::new();
    CHECKOUT.get_or_init(|| {
        if std::env::var_os("TEST_SRCDIR").is_some() {
            let this = std::fs::canonicalize("crates/core/tests/common/mod.rs").expect("this file among the test's runfiles");
            this.ancestors().nth(5).expect("the checkout").to_path_buf()
        } else {
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
        }
    })
}

/// A file or directory of the checkout, from the test's runfiles when it is declared as `data` there.
fn source(path: &str) -> PathBuf {
    if std::env::var_os("TEST_SRCDIR").is_some() && Path::new(path).exists() {
        return std::env::current_dir().expect("the runfiles directory").join(path);
    }
    checkout().join(path)
}

/// Moves the app's cache and data under a directory of this test run, so tests never read or write the
/// reviewer's own. `persistent` names a directory under the checkout's `target` directory that is kept
/// between runs, for the tests that would otherwise start Bazel cold every time.
pub fn home(persistent: Option<&str>) -> &'static Path {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| {
        let dir = match persistent {
            Some(name) => checkout().join("target").join(name),
            None => tempfile::tempdir().expect("a temporary directory").keep(),
        };
        std::fs::create_dir_all(&dir).expect("the test home");
        let dir = std::fs::canonicalize(&dir).expect("the test home");
        // Set once, before any test reads it.
        std::env::set_var("REVIEWMAP_HOME", &dir);
        dir
    })
}

/// A git repository in a temporary directory, removed when the value is dropped, or at a path that is kept.
/// Its commits carry fixed dates, so the same content gives the same commit ids on every run.
pub struct TestRepo {
    root: PathBuf,
    _temporary: Option<tempfile::TempDir>,
}

impl TestRepo {
    pub fn new() -> TestRepo {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let repo = TestRepo { root: dir.path().to_path_buf(), _temporary: Some(dir) };
        repo.git(&["init", "-q", "-b", "main"]);
        repo
    }

    /// A repository made anew at a fixed path. The app keys its Bazel workspaces by the repository's path, so
    /// a test that builds with Bazel finds them warm on its next run.
    pub fn at(path: &Path) -> TestRepo {
        let _ = std::fs::remove_dir_all(path);
        std::fs::create_dir_all(path).expect("the repository's directory");
        let repo = TestRepo { root: path.to_path_buf(), _temporary: None };
        repo.git(&["init", "-q", "-b", "main"]);
        repo
    }

    pub fn path(&self) -> PathBuf {
        std::fs::canonicalize(&self.root).expect("the repository")
    }

    pub fn git(&self, args: &[&str]) -> String {
        let out = Command::new("git")
            .arg("-C")
            .arg(&self.root)
            .args(["-c", "user.email=fixture@example.com", "-c", "user.name=fixture", "-c", "commit.gpgsign=false"])
            .args(args)
            .env("GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z")
            .env("GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z")
            .output()
            .expect("git runs");
        assert!(out.status.success(), "git {args:?} failed: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    pub fn write(&self, path: &str, text: &str) {
        let full = &self.root.join(path);
        std::fs::create_dir_all(full.parent().unwrap()).unwrap();
        std::fs::write(full, text).unwrap();
    }

    pub fn remove(&self, path: &str) {
        std::fs::remove_file(&self.root.join(path)).unwrap();
    }

    /// Commits everything in the working tree and returns the commit.
    pub fn commit(&self, message: &str) -> String {
        self.git(&["add", "-A"]);
        self.git(&["commit", "-qm", message]);
        self.sha("HEAD")
    }

    pub fn sha(&self, rev: &str) -> String {
        self.git(&["rev-parse", rev])
    }

    /// Replaces the working tree with a copy of `from`.
    pub fn replace_tree(&self, from: &Path) {
        for entry in std::fs::read_dir(&self.root).unwrap().flatten() {
            if entry.file_name() == ".git" {
                continue;
            }
            let path = entry.path();
            if path.is_dir() {
                std::fs::remove_dir_all(path).unwrap();
            } else {
                std::fs::remove_file(path).unwrap();
            }
        }
        copy_dir(from, &self.root);
    }
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap().flatten() {
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// A repository with `base` committed on `main` and `head` written over it on the branch `feature`.
/// A `None` in `head` deletes the file.
pub fn two_commits(base: &[(&str, &str)], head: &[(&str, Option<&str>)]) -> TestRepo {
    let repo = TestRepo::new();
    for (path, text) in base {
        repo.write(path, text);
    }
    repo.commit("base");
    repo.git(&["checkout", "-qb", "feature"]);
    for (path, text) in head {
        match text {
            Some(text) => repo.write(path, text),
            None => repo.remove(path),
        }
    }
    repo.commit("head");
    repo
}

/// A repository from a fixture directory that holds a `base` and a `head` tree: `base` on `main`, `head` on `feature`.
pub fn fixture_repo(fixture: &Path) -> TestRepo {
    fill(TestRepo::new(), fixture)
}

/// The same repository at a fixed path (see `TestRepo::at`).
pub fn fixture_repo_at(fixture: &Path, path: &Path) -> TestRepo {
    fill(TestRepo::at(path), fixture)
}

fn fill(repo: TestRepo, fixture: &Path) -> TestRepo {
    repo.replace_tree(&fixture.join("base"));
    repo.commit("base");
    repo.git(&["checkout", "-qb", "feature"]);
    repo.replace_tree(&fixture.join("head"));
    repo.commit("head");
    repo
}

/// A repository at a fixed path with a fixture's trees in the directory `nested`, and `extra` files around
/// them: (path, text at base, text at head).
pub fn nested_fixture_repo_at(fixture: &Path, path: &Path, nested: &str, extra: &[(&str, &str, &str)]) -> TestRepo {
    let repo = TestRepo::at(path);
    let side = |name: &str, head: bool| {
        let _ = std::fs::remove_dir_all(repo.root.join(nested));
        copy_dir(&fixture.join(name), &repo.root.join(nested));
        for (file, base_text, head_text) in extra {
            repo.write(file, if head { head_text } else { base_text });
        }
    };
    side("base", false);
    repo.commit("base");
    repo.git(&["checkout", "-qb", "feature"]);
    side("head", true);
    repo.commit("head");
    repo
}

/// The prototype's fixtures, which the rebuild's tests read in place until the prototype is retired.
pub fn prototype_fixture(name: &str) -> PathBuf {
    source(&format!("Tests/ReviewMapCoreTests/Fixtures/{name}"))
}

pub fn own_fixture(name: &str) -> PathBuf {
    source(&format!("crates/core/tests/fixtures/{name}"))
}

/// `scripts/fake-llm.sh`, the stand-in for `claude` and `codex`. Tests never run a real coding agent: every
/// test that turns the LLM pass on runs this script, or a wrapper around it.
pub fn fake_llm() -> PathBuf {
    let path = match std::env::var_os("REVIEWMAP_FAKE_LLM") {
        Some(p) => std::env::current_dir().expect("the runfiles directory").join(p),
        None => checkout().join("scripts/fake-llm.sh"),
    };
    std::fs::canonicalize(&path).unwrap_or_else(|_| panic!("{} is missing", path.display()))
}

/// LLM options that run `command` and nothing else, without `gh`, so the description is the commit messages
/// on every machine. Replies are cached in the test home's cache (see `home`), keyed by the command among the
/// rest, so a test that runs a command of its own (a wrapper in its own temporary directory) never reads
/// replies that another test cached.
pub fn llm_options(command: &Path) -> reviewmap_core::llm::LlmOptions {
    reviewmap_core::llm::LlmOptions { command: Some(command.to_path_buf()), pull_request: false, jobs: 2, ..Default::default() }
}

/// A script in `dir` that runs the fake with `FAKE_LLM_MODE` set to `mode`, or to `when_matched` for the
/// prompts that contain `pattern` (a grep pattern). Each run adds a line to `<dir>/<name>.calls`.
pub fn fake_llm_wrapper(dir: &Path, name: &str, mode: &str, when_matched: Option<(&str, &str)>) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let fake = fake_llm();
    let pick = match when_matched {
        Some((pattern, other)) => format!("if printf '%s\\n' \"$prompt\" | grep -q -- '{pattern}'; then mode={other}; fi\n"),
        None => String::new(),
    };
    let path = dir.join(name);
    let script = format!(
        "#!/bin/sh\necho run >> '{}.calls'\nprompt=$(cat)\nmode={mode}\n{pick}printf '%s\\n' \"$prompt\" | FAKE_LLM_MODE=$mode '{}' \"$@\"\n",
        path.display(),
        fake.display()
    );
    std::fs::write(&path, script).expect("the wrapper");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("the wrapper is executable");
    path
}

/// How many times a wrapper made by `fake_llm_wrapper` ran.
pub fn fake_llm_calls(wrapper: &Path) -> usize {
    std::fs::read_to_string(format!("{}.calls", wrapper.display())).map(|t| t.lines().count()).unwrap_or(0)
}

/// Runs a review with the LLM pass and returns the final report before the pass and the one after it.
pub fn run_with_llm(mut request: ReviewRequest, options: reviewmap_core::llm::LlmOptions) -> (ChangeReport, ChangeReport) {
    request.llm = Some(options);
    let (_, mut reports, _) = run(request);
    let after = reports.pop().expect("the report after the LLM pass");
    let before = reports.pop().expect("the final report before it");
    assert_eq!(before.analysis.stage, "complete", "the LLM pass runs on the final report");
    (before, after)
}

/// A report without anything the LLM pass adds: what must equal the report before the pass (CORE-004).
pub fn without_llm(report: &ChangeReport) -> ChangeReport {
    let mut r = report.clone();
    r.llm = None;
    r.warnings.retain(|w| !w.kind.starts_with("llm-"));
    r.findings.retain(|f| f.source != "llm");
    for c in &mut r.components {
        c.llm = None;
    }
    for e in &mut r.review_items {
        e.llm = None;
    }
    for g in &mut r.regions {
        g.llm = None;
    }
    r
}

/// `main` → `feature` of a repository, with the defaults a launch has.
pub fn request(repo: &TestRepo) -> ReviewRequest {
    let mut request = ReviewRequest::new(repo.path());
    request.head = Some("feature".to_string());
    request
}

/// Runs a review to its end, as the app does, and returns the session, every report it emitted, and its progress lines.
pub fn run(request: ReviewRequest) -> (Session, Vec<ChangeReport>, Vec<String>) {
    // A test that wants a kept home has set it already; the first call decides.
    home(None);
    let reports = std::sync::Mutex::new(Vec::new());
    let progress = std::sync::Mutex::new(Vec::new());
    let emit = |event: Event| match event {
        Event::Report(report) => reports.lock().unwrap().push(*report),
        Event::Progress(message) => progress.lock().unwrap().push(message),
    };
    let session = session::run(request, &Cancel::new(), &emit).expect("the review runs");
    (session, reports.into_inner().unwrap(), progress.into_inner().unwrap())
}

/// The final report of a review.
pub fn analyze(request: ReviewRequest) -> ChangeReport {
    run(request).1.pop().expect("a report")
}

/// Reads and parses the two revisions without refining, as the first view does.
pub fn open(request: ReviewRequest) -> Session {
    home(None);
    Session::open(request, &Cancel::new(), &|_| {}).expect("the review opens")
}

pub fn changes(report: &ChangeReport) -> BTreeMap<String, ChangeKind> {
    report.review_items.iter().map(|i| (i.qualified_name.clone(), i.change)).collect()
}

pub fn review_item<'a>(report: &'a ChangeReport, name: &str) -> &'a ReviewItem {
    report.review_items.iter().find(|i| i.qualified_name == name).unwrap_or_else(|| {
        panic!("no review item {name}; the report has {:?}", report.review_items.iter().map(|i| &i.qualified_name).collect::<Vec<_>>())
    })
}

pub fn findings<'a>(report: &'a ChangeReport, kind: &str) -> Vec<&'a Finding> {
    report.findings.iter().filter(|f| f.kind == kind).collect()
}

pub fn warning_kinds(report: &ChangeReport) -> Vec<&str> {
    report.warnings.iter().map(|w| w.kind.as_str()).collect()
}

/// Whether the Swift helper is built. Tests that parse Swift return early without it and say so.
pub fn swift_helper() -> bool {
    let found = reviewmap_core::parse::swift_helper::SwiftHelper::locate().is_some();
    if !found {
        eprintln!("skipped: the Swift helper is not built (run `bazel build //helper:reviewmap-swift-helper`, or `bazel test`, which passes it in)");
    }
    found
}
