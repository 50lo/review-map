//! Child processes that the app owns: Bazel, the Swift helper, the Kotlin indexer, downloads. Each one
//! runs in its own process group, is registered with the job's `Cancel`, and is stopped when the job is
//! cancelled or the app exits, so no indexer outlives the review that started it.

use anyhow::{anyhow, Context, Result};
use std::collections::BTreeMap;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

/// A progress callback that may be called from worker threads.
pub type Log<'a> = &'a (dyn Fn(String) + Sync);

/// A cancellation flag shared by everything one job starts, with the process groups to stop.
#[derive(Clone, Default)]
pub struct Cancel {
    flag: Arc<AtomicBool>,
    groups: Arc<Mutex<Vec<i32>>>,
}

#[derive(Debug)]
pub struct Cancelled;

impl std::fmt::Display for Cancelled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "cancelled")
    }
}

impl std::error::Error for Cancelled {}

impl Cancel {
    pub fn new() -> Cancel {
        Cancel::default()
    }

    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    /// Fails with `Cancelled` once the job was cancelled.
    pub fn check(&self) -> Result<()> {
        if self.is_cancelled() {
            Err(anyhow!(Cancelled))
        } else {
            Ok(())
        }
    }

    /// Sets the flag and asks every running child to stop: SIGTERM now, SIGKILL for the ones still alive
    /// two seconds later. Bazel's client forwards the interrupt to its server, which stops the build.
    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
        let groups: Vec<i32> = self.groups.lock().unwrap().clone();
        for g in &groups {
            unsafe { libc::killpg(*g, libc::SIGTERM) };
        }
        if groups.is_empty() {
            return;
        }
        let pending = self.groups.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(2));
            for g in pending.lock().unwrap().iter() {
                unsafe { libc::killpg(*g, libc::SIGKILL) };
            }
        });
    }

    pub fn register(&self, pid: u32) {
        self.groups.lock().unwrap().push(pid as i32);
    }

    pub fn unregister(&self, pid: u32) {
        self.groups.lock().unwrap().retain(|g| *g != pid as i32);
    }
}

/// Whether an error is a cancellation, however deep it is wrapped.
pub fn is_cancelled(error: &anyhow::Error) -> bool {
    error.chain().any(|e| e.downcast_ref::<Cancelled>().is_some())
}

/// Where `[timing]` lines go: the CLI prints them to stderr, the app writes them to its log. Without a sink
/// (tests, the CLI when it only launches the app) they are dropped.
type TimingSink = Box<dyn Fn(&str) + Send + Sync>;
static TIMING_SINK: RwLock<Option<TimingSink>> = RwLock::new(None);

/// Sends every `[timing]` line of this process to `sink`. Worker threads log too, so it must be thread-safe.
pub fn set_timing_log(sink: impl Fn(&str) + Send + Sync + 'static) {
    *TIMING_SINK.write().unwrap_or_else(|e| e.into_inner()) = Some(Box::new(sink));
}

/// Logs that a step took `seconds`, as `[timing] 62.09s <label>`: one line per step, at its end, so a log with
/// timestamps shows when each step ran. The format is what `scripts/bench-phases.py` reads (docs/rebuild-build.md,
/// "Benchmarking a review").
pub fn timing(label: &str, seconds: f64) {
    if let Some(sink) = TIMING_SINK.read().unwrap_or_else(|e| e.into_inner()).as_ref() {
        sink(&format!("[timing] {seconds:.2}s {label}"));
    }
}

/// Times a step: logs its `[timing]` line when dropped, so a step that returns early with an error is logged too.
#[must_use = "a timer logs when it is dropped; bind it to a variable that lives as long as the step"]
pub struct Timer {
    label: String,
    start: Instant,
}

pub fn timer(label: impl Into<String>) -> Timer {
    Timer { label: label.into(), start: Instant::now() }
}

impl Drop for Timer {
    fn drop(&mut self) {
        timing(&self.label, self.start.elapsed().as_secs_f64());
    }
}

/// A command with its environment: the tool environment of `tools::child_env` plus additions.
pub struct Cmd {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub env: BTreeMap<String, String>,
    /// What the command is for, first in its `[timing]` line: `swift index`, `scip-typescript`, ….
    pub what: Option<String>,
    /// More about where it runs, for its `[timing]` line: a Bazel command's side and workspace.
    pub context: Vec<String>,
}

impl Cmd {
    pub fn new(program: impl Into<PathBuf>) -> Cmd {
        Cmd { program: program.into(), args: Vec::new(), cwd: None, env: BTreeMap::new(), what: None, context: Vec::new() }
    }

    /// Says what the command is for, in its `[timing]` line.
    pub fn what(mut self, purpose: impl Into<String>) -> Cmd {
        self.what = Some(purpose.into());
        self
    }

    /// Adds to where the command runs, in its `[timing]` line.
    pub fn context(mut self, note: impl Into<String>) -> Cmd {
        self.context.push(note.into());
        self
    }

    pub fn arg(mut self, a: impl Into<String>) -> Cmd {
        self.args.push(a.into());
        self
    }

    pub fn args<I, S>(mut self, list: I) -> Cmd
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args.extend(list.into_iter().map(Into::into));
        self
    }

    pub fn cwd(mut self, dir: &Path) -> Cmd {
        self.cwd = Some(dir.to_path_buf());
        self
    }

    pub fn env(mut self, key: &str, value: &str) -> Cmd {
        self.env.insert(key.to_string(), value.to_string());
        self
    }

    pub fn display(&self) -> String {
        std::iter::once(self.program.display().to_string()).chain(self.args.iter().cloned()).collect::<Vec<_>>().join(" ")
    }

    fn command(&self) -> Command {
        let mut c = Command::new(&self.program);
        c.args(&self.args);
        if let Some(cwd) = &self.cwd {
            c.current_dir(cwd);
        }
        c.env("PATH", crate::tools::child_path());
        for (k, v) in &self.env {
            c.env(k, v);
        }
        c.stdin(Stdio::null());
        // Its own process group, so cancelling stops the tool and everything it started.
        c.process_group(0);
        c
    }

    /// Runs the command and returns its standard output. Fails on a non-zero exit, with the end of its
    /// standard error in the message.
    pub fn output(&self, cancel: &Cancel) -> Result<Vec<u8>> {
        let timer = timer(self.timing_label());
        let result = self.output_inner(cancel);
        drop(timer);
        self.keep_profile();
        result
    }

    fn output_inner(&self, cancel: &Cancel) -> Result<Vec<u8>> {
        cancel.check()?;
        let mut command = self.command();
        command.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = command.spawn().with_context(|| format!("could not start {}", self.program.display()))?;
        let pid = child.id();
        cancel.register(pid);
        let mut out = child.stdout.take().unwrap();
        let mut err = child.stderr.take().unwrap();
        let err_reader = std::thread::spawn(move || {
            let mut s = Vec::new();
            let _ = err.read_to_end(&mut s);
            s
        });
        let mut stdout = Vec::new();
        let _ = out.read_to_end(&mut stdout);
        let status = child.wait();
        cancel.unregister(pid);
        let stderr = err_reader.join().unwrap_or_default();
        cancel.check()?;
        let status = status?;
        if !status.success() {
            let text = String::from_utf8_lossy(&stderr);
            let tail: Vec<&str> = text.lines().rev().take(12).collect();
            let tail: Vec<&str> = tail.into_iter().rev().collect();
            return Err(anyhow!("`{}` failed ({}): {}", self.display(), status, tail.join("\n")));
        }
        Ok(stdout)
    }

    /// Like `output`, but the exit status doesn't matter: for tools that print what they have and then report errors.
    pub fn output_lenient(&self, cancel: &Cancel) -> Result<Vec<u8>> {
        let timer = timer(self.timing_label());
        let result = self.output_lenient_inner(cancel);
        drop(timer);
        self.keep_profile();
        result
    }

    fn output_lenient_inner(&self, cancel: &Cancel) -> Result<Vec<u8>> {
        cancel.check()?;
        let mut command = self.command();
        command.stdout(Stdio::piped()).stderr(Stdio::null());
        let mut child = command.spawn().with_context(|| format!("could not start {}", self.program.display()))?;
        let pid = child.id();
        cancel.register(pid);
        let mut stdout = Vec::new();
        let _ = child.stdout.take().unwrap().read_to_end(&mut stdout);
        let _ = child.wait();
        cancel.unregister(pid);
        cancel.check()?;
        Ok(stdout)
    }

    /// `cmd <program> [<bazel command>] (<what>, <context>…)`. Never the arguments: they hold paths, and a
    /// Bazel command's `--output_base` would make the same step look different in every home.
    fn timing_label(&self) -> String {
        let mut label = format!("cmd {}", self.program.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default());
        if let Some(command) = self.bazel_command() {
            label.push(' ');
            label.push_str(command);
        }
        let notes: Vec<&str> = self.what.iter().chain(self.context.iter()).map(String::as_str).collect();
        if !notes.is_empty() {
            label.push_str(&format!(" ({})", notes.join(", ")));
        }
        label
    }

    /// For a Bazel command (one with `--output_base`): the command after the startup options.
    fn bazel_command(&self) -> Option<&str> {
        self.output_base()?;
        self.args.iter().find(|a| !a.starts_with('-')).map(String::as_str)
    }

    fn output_base(&self) -> Option<&str> {
        self.args.iter().find_map(|a| a.strip_prefix("--output_base="))
    }

    /// With `REVIEWMAP_PROFILE_DIR` set (scripts/bench-review.sh --profiles), keeps a copy of a Bazel command's
    /// JSON trace profile, which Bazel rewrites with every build or query, as `<dir>/<n>-<command>-<side>-<output base>.profile.gz`.
    /// `bazel info` writes none, so the file it leaves is the previous command's.
    fn keep_profile(&self) {
        static KEPT: AtomicUsize = AtomicUsize::new(0);
        let (Some(dir), Some(base), Some(command)) = (std::env::var_os("REVIEWMAP_PROFILE_DIR"), self.output_base(), self.bazel_command()) else { return };
        if command == "info" {
            return;
        }
        let base = Path::new(base);
        let from = base.join("command.profile.gz");
        if !from.exists() {
            return;
        }
        let side = base.parent().and_then(Path::parent).and_then(Path::file_name).map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let name = base.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let n = KEPT.fetch_add(1, Ordering::SeqCst);
        let dir = PathBuf::from(dir);
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::copy(from, dir.join(format!("{n:03}-{command}-{side}-{name}.profile.gz")));
    }

    pub fn output_string(&self, cancel: &Cancel) -> Result<String> {
        Ok(String::from_utf8_lossy(&self.output(cancel)?).trim().to_string())
    }

    /// Runs the command with its output appended to a log file, and returns its exit status.
    pub fn run_logged(&self, log: &Path, cancel: &Cancel) -> Result<ExitStatus> {
        let timer = timer(self.timing_label());
        let result = self.run_logged_inner(log, cancel);
        drop(timer);
        self.keep_profile();
        result
    }

    fn run_logged_inner(&self, log: &Path, cancel: &Cancel) -> Result<ExitStatus> {
        cancel.check()?;
        if let Some(dir) = log.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut file = OpenOptions::new().create(true).append(true).open(log)?;
        writeln!(file, "$ {}\n", self.display())?;
        let mut command = self.command();
        command.stdout(file.try_clone()?).stderr(file.try_clone()?);
        let mut child = command.spawn().with_context(|| format!("could not start {}", self.program.display()))?;
        let status = wait(&mut child, cancel);
        let _ = writeln!(file);
        cancel.check()?;
        status
    }
}

/// Waits for a child that is registered with the job, so that cancelling stops it.
pub fn wait(child: &mut Child, cancel: &Cancel) -> Result<ExitStatus> {
    let pid = child.id();
    cancel.register(pid);
    let status = child.wait();
    cancel.unregister(pid);
    Ok(status?)
}

/// Stops a process group: SIGTERM, then SIGKILL after a grace period when it is still alive.
pub fn stop_group(pid: u32, grace: Duration) {
    unsafe { libc::killpg(pid as i32, libc::SIGTERM) };
    let start = Instant::now();
    while start.elapsed() < grace {
        if unsafe { libc::kill(pid as i32, 0) } != 0 {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
}

/// The last lines of a log file, for an error message.
pub fn log_tail(path: &Path, lines: usize) -> String {
    let Ok(text) = std::fs::read_to_string(path) else { return String::new() };
    let all: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    all[all.len().saturating_sub(lines)..].join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bazel::workspace::BazelEnv;

    #[test]
    fn a_bazel_command_is_labelled_by_its_command_side_and_workspace_never_its_output_base() {
        let root = PathBuf::from("/home/cache/bazel/repo-1");
        let env = BazelEnv::new("/bin/bazel".into(), root.join("head/tree/crates/core/tests/fixtures/ts-bazel/head"), root.join("head/out/ts-bazel-head"), Vec::new());
        let cmd = env.command("build").what("typescript index").arg("--keep_going").arg("--").arg("//...");
        assert_eq!(cmd.timing_label(), r#"cmd bazel build (typescript index, head, workspace "crates/core/tests/fixtures/ts-bazel/head")"#);
        let root_env = BazelEnv::new("/bin/bazel".into(), root.join("base/tree"), root.join("base/out/_root"), Vec::new());
        assert_eq!(root_env.command("cquery").what("graph").timing_label(), r#"cmd bazel cquery (graph, base, workspace "")"#);
    }

    #[test]
    fn other_commands_are_labelled_by_their_program_and_purpose() {
        let cmd = Cmd::new("/usr/bin/curl").what("download").args(["-fsSL", "-o", "/tmp/x", "https://example.invalid/x"]);
        assert_eq!(cmd.timing_label(), "cmd curl (download)");
        assert_eq!(Cmd::new("/usr/bin/java").arg("-version").timing_label(), "cmd java");
    }
}
