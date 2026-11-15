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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
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

/// A command with its environment: the tool environment of `tools::child_env` plus additions.
pub struct Cmd {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub env: BTreeMap<String, String>,
}

impl Cmd {
    pub fn new(program: impl Into<PathBuf>) -> Cmd {
        Cmd { program: program.into(), args: Vec::new(), cwd: None, env: BTreeMap::new() }
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

    pub fn output_string(&self, cancel: &Cancel) -> Result<String> {
        Ok(String::from_utf8_lossy(&self.output(cancel)?).trim().to_string())
    }

    /// Runs the command with its output appended to a log file, and returns its exit status.
    pub fn run_logged(&self, log: &Path, cancel: &Cancel) -> Result<ExitStatus> {
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
