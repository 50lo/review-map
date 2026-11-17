//! The Review Map app: one window with the bundled review UI, and the commands that UI calls.
//!
//! There is no HTTP server and no port. `reviewmap` starts this executable with the review as arguments;
//! when the app is already running, the single-instance plugin hands those arguments to the running
//! process, which focuses its window and starts the review. One review runs at a time, on its own
//! thread; starting another cancels the one in progress. The app owns every process a review starts and
//! stops them when the review is cancelled or the app exits, along with the Bazel servers it started.

mod editor;
mod menu;
mod settings;
mod zoom;

use reviewmap_core::git::Repo;
use reviewmap_core::llm::LlmOptions;
use reviewmap_core::model::{ChangeReport, Side};
use reviewmap_core::proc::Cancel;
use reviewmap_core::session::{self, Event, ReviewRequest, Session};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, RunEvent, State};

const EVENT: &str = "review://event";

/// Appends a line to the app's log (`<cache>/logs/app.log`): what was launched, each review's progress, and
/// how it ended. `reviewmap` starts the app detached from the terminal, so this is where to look when a
/// review doesn't behave. The log starts over when it passes a few megabytes.
fn log(line: impl AsRef<str>) {
    use std::io::Write;
    // Review threads and the UI's commands log at the same time: one writer at a time, one write per line.
    static WRITING: Mutex<()> = Mutex::new(());
    let _writing = WRITING.lock().unwrap_or_else(|e| e.into_inner());
    let dir = reviewmap_core::store::cache_root().join("logs");
    let path = dir.join("app.log");
    let _ = std::fs::create_dir_all(&dir);
    if std::fs::metadata(&path).map(|m| m.len() > 4 * 1024 * 1024).unwrap_or(false) {
        let _ = std::fs::rename(&path, dir.join("app.previous.log"));
    }
    if let Ok(mut file) = std::fs::File::options().create(true).append(true).open(&path) {
        let seconds = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let _ = file.write_all(format!("{seconds} [{}] {}\n", std::process::id(), line.as_ref()).as_bytes());
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct JobState {
    id: u64,
    request: ReviewRequest,
    running: bool,
    /// The latest progress line.
    message: String,
    cancelled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

struct Job {
    state: JobState,
    cancel: Cancel,
}

#[derive(Default)]
struct Inner {
    next_id: u64,
    job: Option<Job>,
    /// The latest report of the current review.
    report: Option<Arc<ChangeReport>>,
    /// The session of the current review, once its analysis ended. The comparison report comes from it.
    session: Option<Arc<Session>>,
    name_based: Option<Arc<ChangeReport>>,
    /// The repository and commits of the report on screen, for reading sources.
    sources: Option<(Repo, String, String)>,
}

#[derive(Default)]
struct AppState(Mutex<Inner>);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    #[serde(skip_serializing_if = "Option::is_none")]
    job: Option<JobState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    report: Option<Arc<ChangeReport>>,
    editor: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum ReviewEvent {
    Started {
        job: JobState,
    },
    #[serde(rename_all = "camelCase")]
    Progress {
        job_id: u64,
        message: String,
    },
    #[serde(rename_all = "camelCase")]
    Report {
        job_id: u64,
        report: Arc<ChangeReport>,
    },
    #[serde(rename_all = "camelCase")]
    Finished {
        job_id: u64,
        cancelled: bool,
    },
    #[serde(rename_all = "camelCase")]
    Failed {
        job_id: u64,
        error: String,
    },
}

/// Starts a review on its own thread, cancelling the one in progress. Returns the job's id.
fn start(app: &AppHandle, mut request: ReviewRequest) -> u64 {
    // An empty head means the checked-out branch.
    request.head = request.head.filter(|h| !h.trim().is_empty());
    let state = app.state::<AppState>();
    let (id, cancel, job_state) = {
        let mut inner = state.0.lock().unwrap();
        if let Some(job) = &inner.job {
            job.cancel.cancel();
        }
        inner.next_id += 1;
        let id = inner.next_id;
        let cancel = Cancel::new();
        let job_state = JobState { id, request: request.clone(), running: true, message: "Starting the review".to_string(), cancelled: false, error: None };
        inner.job = Some(Job { state: job_state.clone(), cancel: cancel.clone() });
        inner.report = None;
        inner.session = None;
        inner.name_based = None;
        inner.sources = None;
        (id, cancel, job_state)
    };
    log(format!(
        "review {id}: {} {} -> {}{}",
        request.repo.display(),
        request.base,
        request.head.as_deref().unwrap_or("(checked-out branch)"),
        if request.targets.is_empty() { String::new() } else { format!(" targets {}", request.targets.join(" ")) }
    ));
    let _ = app.emit(EVENT, ReviewEvent::Started { job: job_state });
    let app = app.clone();
    std::thread::Builder::new()
        .name(format!("review-{id}"))
        .spawn(move || {
            let current = |inner: &Inner| inner.job.as_ref().map(|j| j.state.id) == Some(id);
            let emit = |event: Event| {
                let state = app.state::<AppState>();
                match event {
                    Event::Progress(message) => {
                        let mut inner = state.0.lock().unwrap();
                        if !current(&inner) {
                            return;
                        }
                        if let Some(job) = inner.job.as_mut() {
                            job.state.message = message.clone();
                        }
                        drop(inner);
                        log(format!("review {id}: {message}"));
                        let _ = app.emit(EVENT, ReviewEvent::Progress { job_id: id, message });
                    }
                    Event::Report(report) => {
                        let report = Arc::new(*report);
                        let mut inner = state.0.lock().unwrap();
                        if !current(&inner) {
                            return;
                        }
                        if inner.sources.is_none() {
                            if let Ok(repo) = Repo::discover(std::path::Path::new(&report.repo.root)) {
                                inner.sources = Some((repo, report.repo.base_sha.clone(), report.repo.head_sha.clone()));
                            }
                            // The first report: the review could be opened, so it is worth offering again.
                            if let Some(job) = &inner.job {
                                settings::remember(&job.state.request);
                            }
                        }
                        inner.report = Some(report.clone());
                        // A refined report makes an earlier comparison stale.
                        inner.name_based = None;
                        drop(inner);
                        log(format!(
                            "review {id}: report ({}, {} review items, {} edges, {} warnings)",
                            report.analysis.stage,
                            report.review_items.len(),
                            report.edges.len(),
                            report.warnings.len()
                        ));
                        let _ = app.emit(EVENT, ReviewEvent::Report { job_id: id, report });
                    }
                }
            };
            let result = session::run(request, &cancel, &emit);
            let state = app.state::<AppState>();
            let mut inner = state.0.lock().unwrap();
            if !current(&inner) {
                return;
            }
            let event = match result {
                Ok(session) => {
                    inner.session = Some(Arc::new(session));
                    ReviewEvent::Finished { job_id: id, cancelled: cancel.is_cancelled() }
                }
                Err(e) if reviewmap_core::proc::is_cancelled(&e) => ReviewEvent::Finished { job_id: id, cancelled: true },
                Err(e) => ReviewEvent::Failed { job_id: id, error: format!("{e:#}") },
            };
            if let Some(job) = inner.job.as_mut() {
                job.state.running = false;
                job.state.message.clear();
                match &event {
                    ReviewEvent::Finished { cancelled, .. } => job.state.cancelled = *cancelled,
                    ReviewEvent::Failed { error, .. } => job.state.error = Some(error.clone()),
                    _ => {}
                }
            }
            drop(inner);
            match &event {
                ReviewEvent::Finished { cancelled, .. } => log(format!("review {id}: {}", if *cancelled { "cancelled" } else { "finished" })),
                ReviewEvent::Failed { error, .. } => log(format!("review {id}: failed: {error}")),
                _ => {}
            }
            let _ = app.emit(EVENT, event);
        })
        .expect("the review thread starts");
    id
}

// MARK: Commands

#[tauri::command]
fn current_state(state: State<AppState>) -> Snapshot {
    let inner = state.0.lock().unwrap();
    log(format!("ui: asked for the current state (report: {})", if inner.report.is_some() { "yes" } else { "no" }));
    Snapshot { job: inner.job.as_ref().map(|j| j.state.clone()), report: inner.report.clone(), editor: editor::current().map(|e| e.name) }
}

#[tauri::command]
fn start_review(app: AppHandle, mut request: ReviewRequest) -> Result<u64, String> {
    if request.repo.as_os_str().is_empty() {
        return Err("Give the path of a repository.".to_string());
    }
    // A review started in the window follows the settings for the LLM pass.
    if request.llm.is_none() {
        request.llm = settings::load().llm;
    }
    Repo::discover(&request.repo).map_err(|e| format!("{e:#}"))?;
    Ok(start(&app, request))
}

#[tauri::command]
fn cancel_review(state: State<AppState>) {
    if let Some(job) = &state.0.lock().unwrap().job {
        job.cancel.cancel();
    }
}

/// The comparison report: the same revisions with every reference matched by name.
#[tauri::command]
async fn name_based_report(app: AppHandle) -> Result<Arc<ChangeReport>, String> {
    let session = {
        let state = app.state::<AppState>();
        let inner = state.0.lock().unwrap();
        if let Some(have) = &inner.name_based {
            return Ok(have.clone());
        }
        inner.session.clone().ok_or_else(|| "The comparison is ready once the analysis has finished.".to_string())?
    };
    let for_thread = session.clone();
    let report = tauri::async_runtime::spawn_blocking(move || Arc::new(for_thread.name_based_report())).await.map_err(|e| e.to_string())?;
    let state = app.state::<AppState>();
    let mut inner = state.0.lock().unwrap();
    // Only kept for the review it was made for.
    if inner.session.as_ref().map(|s| Arc::ptr_eq(s, &session)).unwrap_or(false) {
        inner.name_based = Some(report.clone());
    }
    Ok(report)
}

/// Paths that could escape the tree or be read as an option are refused.
fn safe_relative(file: &str) -> bool {
    !file.is_empty() && !file.starts_with('/') && !file.starts_with('-') && !file.split('/').any(|p| p == "..") && !file.contains('\0')
}

#[tauri::command]
async fn read_source(app: AppHandle, side: Side, file: String) -> Option<String> {
    if !safe_relative(&file) {
        return None;
    }
    let (repo, base, head) = app.state::<AppState>().0.lock().unwrap().sources.clone()?;
    tauri::async_runtime::spawn_blocking(move || {
        let sha = if side == Side::Base { base } else { head };
        let commit = repo.resolve(&sha).ok()?;
        repo.read_path(commit, &file).ok().flatten().map(|b| String::from_utf8_lossy(&b).into_owned())
    })
    .await
    .ok()
    .flatten()
}

#[tauri::command]
fn open_in_editor(state: State<AppState>, file: String, line: u32) -> Result<String, String> {
    if !safe_relative(&file) {
        return Err("Invalid path.".to_string());
    }
    let root = state.0.lock().unwrap().sources.as_ref().map(|s| s.0.root().to_path_buf()).ok_or_else(|| "No review is open.".to_string())?;
    editor::open(&root, &file, line)
}

fn review_file(root: &str, head: &str) -> PathBuf {
    session::review_state_dir(std::path::Path::new(root)).join(format!("{}.json", reviewmap_core::git::slug(head)))
}

/// Reviewed marks and notes of one head commit. They live in the app's data directory, apart from the cache.
#[tauri::command]
fn load_review_state(root: String, head: String, head_sha: String) -> Option<serde_json::Value> {
    log(format!("ui: showing a review of {root} at {}", &head_sha[..head_sha.len().min(8)]));
    let data = std::fs::read(review_file(&root, &head)).ok()?;
    let all: serde_json::Value = serde_json::from_slice(&data).ok()?;
    all.get(&head_sha).cloned()
}

#[tauri::command]
fn save_review_state(root: String, head: String, head_sha: String, state: serde_json::Value) -> Result<(), String> {
    let path = review_file(&root, &head);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut all: serde_json::Map<String, serde_json::Value> =
        std::fs::read(&path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
    all.insert(head_sha, state);
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(&all).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

/// A failure in the UI, for the app log: the window has no console a person can read.
#[tauri::command]
fn log_ui_error(message: String) {
    let text: String = message.chars().take(4000).collect();
    log(format!("ui error: {text}"));
}

/// The UI's state for the menu bar's own items: whether New Review…, the comparison and the two notes items
/// can be used, and whether the comparison report is on screen (the comparison item's check mark).
#[tauri::command]
fn set_menu_state(app: AppHandle, state: menu::MenuState) -> Result<(), String> {
    log(format!(
        "ui: menu state: new review {}, comparison {}, comparison shown {}, notes {}",
        state.can_start_new, state.can_compare, state.name_based, state.has_notes
    ));
    match app.try_state::<menu::AppMenu<tauri::Wry>>() {
        Some(items) => items.apply(state).map_err(|e| e.to_string()),
        None => Ok(()),
    }
}

/// Puts text on the system clipboard, for the notes' Copy actions. Through the app rather than the web view's
/// clipboard API, which WebKit allows only during a click in the page: Edit → Copy Notes as Markdown is a click
/// in the menu bar.
#[tauri::command]
fn copy_text(text: String) -> Result<(), String> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    // pbcopy reads its input in the locale's encoding; an app opened from Finder has none, and anything
    // beyond ASCII would be mangled.
    let mut child = Command::new("/usr/bin/pbcopy")
        .env("LANG", "en_US.UTF-8")
        .env("LC_CTYPE", "UTF-8")
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|e| format!("pbcopy: {e}"))?;
    child.stdin.take().ok_or("pbcopy: no input")?.write_all(text.as_bytes()).map_err(|e| format!("pbcopy: {e}"))?;
    let status = child.wait().map_err(|e| format!("pbcopy: {e}"))?;
    if !status.success() {
        log(format!("ui: copying {} bytes failed: pbcopy {status}", text.len()));
        return Err(format!("pbcopy {status}"));
    }
    log(format!("ui: copied {} bytes to the clipboard", text.len()));
    Ok(())
}

/// Saves the review notes (Markdown) where the person picks in the system's save dialog, `review-notes.md`
/// by default. The path of the saved file, or None when the dialog was dismissed. The web view itself can't
/// save: WKWebView drops a download link's navigation when the app sets no download handler.
///
/// Async, so it runs off the main thread: the dialog runs on the main thread and this waits for it.
#[tauri::command]
async fn export_notes(app: AppHandle, markdown: String) -> Result<Option<String>, String> {
    use tauri_plugin_dialog::DialogExt;
    let picked = app.dialog().file().set_title("Export Notes").set_file_name("review-notes.md").add_filter("Markdown", &["md"]).blocking_save_file();
    let Some(picked) = picked else {
        log("ui: export notes: dismissed");
        return Ok(None);
    };
    let path = picked.into_path().map_err(|e| e.to_string())?;
    match std::fs::write(&path, markdown.as_bytes()) {
        Ok(()) => {
            log(format!("ui: exported notes ({} bytes) to {}", markdown.len(), path.display()));
            Ok(Some(path.display().to_string()))
        }
        Err(e) => {
            log(format!("ui: exporting notes to {} failed: {e}", path.display()));
            Err(format!("Couldn't save {}: {e}", path.display()))
        }
    }
}

#[tauri::command]
fn recent_reviews() -> Vec<settings::Recent> {
    settings::load().recent
}

#[derive(Serialize)]
struct RepoDefaults {
    root: String,
    branch: String,
}

/// The root and the checked-out branch of the repository around a path, for the start form.
#[tauri::command]
fn repo_defaults(path: String) -> Result<RepoDefaults, String> {
    let expanded = match path.strip_prefix("~/") {
        Some(rest) => std::env::var("HOME").map(|h| format!("{h}/{rest}")).unwrap_or(path.clone()),
        None => path.clone(),
    };
    let repo = Repo::discover(std::path::Path::new(&expanded)).map_err(|_| format!("{path} is not inside a git repository."))?;
    Ok(RepoDefaults { root: repo.root().to_string_lossy().to_string(), branch: repo.current_branch() })
}

// MARK: Launching

/// The review in a command line: what `reviewmap` passes. None when the arguments name no repository. The LLM
/// pass follows `llm_setting` unless the launch says otherwise: `--no-llm` turns it off, and `--llm`,
/// `--llm-command`, and `--llm-model` change what the setting says (a different tool starts from its defaults).
fn request_from_args(args: &[String], llm_setting: Option<&LlmOptions>) -> Option<ReviewRequest> {
    let mut request: Option<ReviewRequest> = None;
    let mut pending: Vec<(String, String)> = Vec::new();
    let mut flags: Vec<String> = Vec::new();
    let mut i = 1;
    while i < args.len() {
        let arg = &args[i];
        match arg.as_str() {
            "--repo" | "--base" | "--head" | "--cwd" | "--target" | "--llm" | "--llm-command" | "--llm-model" if i + 1 < args.len() => {
                pending.push((arg.clone(), args[i + 1].clone()));
                i += 1;
            }
            other if other.starts_with("--bazel-arg=") => pending.push(("--bazel-arg".to_string(), other["--bazel-arg=".len()..].to_string())),
            other => flags.push(other.to_string()),
        }
        i += 1;
    }
    for (key, value) in &pending {
        if key == "--repo" {
            request = Some(ReviewRequest::new(PathBuf::from(value)));
        }
    }
    let mut request = request?;
    let mut llm: Option<LlmOptions> = None;
    let mut llm_given = false;
    let base = || llm_setting.cloned().unwrap_or_default();
    // The tool first, so that a different tool starts from its defaults before the command and model apply.
    if let Some((_, tool)) = pending.iter().find(|(k, _)| k == "--llm") {
        let o = llm.get_or_insert_with(base);
        if o.tool != *tool {
            *o = LlmOptions { tool: tool.clone(), ..LlmOptions::default() };
        }
        llm_given = true;
    }
    for (key, value) in pending {
        match key.as_str() {
            "--llm" => {}
            "--llm-command" => {
                llm.get_or_insert_with(base).command = Some(PathBuf::from(value));
                llm_given = true;
            }
            "--llm-model" => {
                llm.get_or_insert_with(base).model = Some(value);
                llm_given = true;
            }
            "--base" => request.base = value,
            "--head" => request.head = Some(value),
            "--cwd" => request.cwd = Some(PathBuf::from(value)),
            "--target" => request.targets.push(value),
            "--bazel-arg" => request.bazel_args.push(value),
            _ => {}
        }
    }
    for flag in &flags {
        match flag.as_str() {
            "--no-merge-base" => request.use_merge_base = false,
            "--no-index" => request.index = Some(false),
            "--index" => request.index = Some(true),
            _ => {}
        }
    }
    request.llm = if flags.iter().any(|f| f == "--no-llm") {
        None
    } else if llm_given {
        llm
    } else {
        llm_setting.cloned()
    };
    Some(request)
}

fn focus(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

pub fn run() {
    let loaded = settings::load();
    settings::apply(&loaded);
    log(format!("started: {}", std::env::args().collect::<Vec<_>>().join(" ")));
    // How long each step of a review took: Bazel commands, index reads, report builds (docs/rebuild-build.md).
    reviewmap_core::proc::set_timing_log(|line: &str| log(line));
    let app = tauri::Builder::default()
        // Another start of the app lands here, in the instance that is already running.
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            log(format!("another launch: {}", args.join(" ")));
            focus(app);
            // The settings are read again: they may have changed since the app started.
            if let Some(request) = request_from_args(&args, settings::load().llm.as_ref()) {
                start(app, request);
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            current_state,
            start_review,
            cancel_review,
            name_based_report,
            read_source,
            open_in_editor,
            load_review_state,
            save_review_state,
            recent_reviews,
            repo_defaults,
            log_ui_error,
            set_menu_state,
            copy_text,
            export_notes
        ])
        .on_menu_event(menu::on_event)
        .setup(move |app| {
            // Without the menu bar the app still reviews; the menu's two items are then missing.
            if let Err(e) = menu::install(app.handle()) {
                log(format!("the menu bar could not be built: {e}"));
            }
            // The zoom chosen last time, from View → Zoom In or Zoom Out.
            if let Some(z) = loaded.zoom {
                zoom::apply(app.handle(), zoom::clamp(Some(z)));
            }
            let args: Vec<String> = std::env::args().collect();
            if let Some(request) = request_from_args(&args, loaded.llm.as_ref()) {
                start(app.handle(), request);
            }
            // The caches are disposable; keep them under their limit without holding up the window.
            let limit = loaded.cache_limit_bytes();
            let idle_days = loaded.idle_workspace_days();
            std::thread::spawn(move || reviewmap_core::store::evict(limit, idle_days));
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("the Review Map app starts");
    app.run(|app, event| {
        if let RunEvent::Exit = event {
            log("exiting: stopping the review's processes and the Bazel servers");
            // Nothing the app started outlives it: the review's processes, then the Bazel servers.
            if let Some(job) = &app.state::<AppState>().0.lock().unwrap().job {
                job.cancel.cancel();
            }
            reviewmap_core::bazel::workspace::shutdown_all();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_launch() {
        let args: Vec<String> = ["app", "--repo", "/r", "--base", "develop", "--head", "feature/x", "--cwd", "/r/ios", "--target", "//App:App", "--bazel-arg=--config=sim", "--no-merge-base"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let r = request_from_args(&args, None).unwrap();
        assert_eq!(r.repo, PathBuf::from("/r"));
        assert_eq!((r.base.as_str(), r.head.as_deref()), ("develop", Some("feature/x")));
        assert_eq!(r.targets, vec!["//App:App".to_string()]);
        assert_eq!(r.bazel_args, vec!["--config=sim".to_string()]);
        assert!(!r.use_merge_base);
        assert_eq!(r.llm, None, "the LLM pass is off without a setting or a flag");
        assert!(request_from_args(&["app".to_string()], None).is_none());
    }

    fn args(list: &[&str]) -> Vec<String> {
        ["app", "--repo", "/r"].iter().chain(list).map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_launch_overrides_the_llm_setting() {
        let setting = LlmOptions { tool: "claude".to_string(), model: Some("sonnet".to_string()), ..LlmOptions::default() };
        // Nothing said: the setting.
        assert_eq!(request_from_args(&args(&[]), Some(&setting)).unwrap().llm, Some(setting.clone()));
        // --no-llm wins over the setting.
        assert_eq!(request_from_args(&args(&["--no-llm"]), Some(&setting)).unwrap().llm, None);
        // A command keeps the rest of the setting.
        let fake = request_from_args(&args(&["--llm-command", "/x/fake-llm.sh"]), Some(&setting)).unwrap().llm.unwrap();
        assert_eq!((fake.tool.as_str(), fake.model.as_deref(), fake.command), ("claude", Some("sonnet"), Some(PathBuf::from("/x/fake-llm.sh"))));
        // Another tool starts from its defaults: the setting's model is claude's.
        let codex = request_from_args(&args(&["--llm", "codex"]), Some(&setting)).unwrap().llm.unwrap();
        assert_eq!((codex.tool.as_str(), codex.model), ("codex", None));
        // Without a setting, --llm turns the pass on.
        assert_eq!(request_from_args(&args(&["--llm", "claude"]), None).unwrap().llm.map(|o| o.tool), Some("claude".to_string()));
    }

    #[test]
    fn refuses_paths_outside_the_tree() {
        assert!(safe_relative("Sources/App.swift"));
        assert!(!safe_relative("../secret"));
        assert!(!safe_relative("/etc/passwd"));
        assert!(!safe_relative("-rf"));
    }
}
