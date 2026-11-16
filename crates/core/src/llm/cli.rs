//! Running a coding-agent CLI: `claude -p --output-format json` or `codex exec`, with the prompt on stdin,
//! in an empty temporary directory so that the agent never sees or touches the reviewed repository
//! (CORE-002). The child runs in its own process group and is registered with the job's `Cancel`, so
//! cancelling the review stops it; a call that runs past the timeout is stopped too.

use super::LlmOptions;
use crate::proc::Cancel;
use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// Why a call gave no reply text.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum CallError {
    /// The CLI can't run at all: missing, not executable, or exited with 127. Further calls would fail the
    /// same way, so the pass stops and the report says so with an `llm-unavailable` warning.
    Unavailable(String),
    /// This call failed: a non-zero exit, a timeout, an error result. The batch may retry.
    Failed(String),
    /// The review was cancelled.
    Cancelled,
}

/// What a child process left behind.
pub(crate) struct Output {
    pub status: Option<ExitStatus>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub timed_out: bool,
}

/// Runs `program` with `input` on stdin, in `cwd`, until it exits, the timeout passes, or the job is
/// cancelled. Fails only when the program can't be started.
pub(crate) fn run(program: &Path, args: &[String], input: &[u8], cwd: &Path, timeout: Duration, cancel: &Cancel) -> std::io::Result<Output> {
    let mut command = Command::new(program);
    command
        .args(args)
        .current_dir(cwd)
        .env("PATH", crate::tools::child_path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Its own process group, so stopping it stops whatever it started.
        .process_group(0);
    let mut child = command.spawn()?;
    let pid = child.id();
    cancel.register(pid);
    // Prompts are larger than a pipe's buffer, so the prompt is written while the output is read. A CLI
    // that exits without reading it makes the write fail, which doesn't matter.
    let mut stdin = child.stdin.take().expect("piped stdin");
    let input = input.to_vec();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&input);
    });
    let mut out = child.stdout.take().expect("piped stdout");
    let mut err = child.stderr.take().expect("piped stderr");
    let out_reader = std::thread::spawn(move || {
        let mut v = Vec::new();
        let _ = out.read_to_end(&mut v);
        v
    });
    let err_reader = std::thread::spawn(move || {
        let mut v = Vec::new();
        let _ = err.read_to_end(&mut v);
        v
    });
    let start = Instant::now();
    let mut timed_out = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {}
            Err(_) => break None,
        }
        if cancel.is_cancelled() || start.elapsed() >= timeout {
            timed_out = !cancel.is_cancelled();
            stop(&mut child, pid);
            break child.wait().ok();
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    cancel.unregister(pid);
    let _ = writer.join();
    let stdout = out_reader.join().unwrap_or_default();
    let stderr = err_reader.join().unwrap_or_default();
    Ok(Output { status, stdout, stderr, timed_out })
}

/// SIGTERM to the child's group, then SIGKILL when it hasn't exited two seconds later.
fn stop(child: &mut std::process::Child, pid: u32) {
    unsafe { libc::killpg(pid as i32, libc::SIGTERM) };
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(2) {
        if matches!(child.try_wait(), Ok(Some(_))) {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
}

/// An empty directory of its own for one call, removed when dropped.
struct CallDir(PathBuf);

impl CallDir {
    fn new() -> std::io::Result<CallDir> {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("reviewmap-llm-{}-{}-{nanos}", std::process::id(), NEXT.fetch_add(1, Ordering::SeqCst)));
        std::fs::create_dir_all(&dir)?;
        Ok(CallDir(dir))
    }
}

impl Drop for CallDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Runs the configured CLI on prompts.
pub(crate) struct Runner<'a> {
    options: &'a LlmOptions,
    cancel: &'a Cancel,
    /// The executable, found on the first call: a cached review never needs it.
    program: std::sync::OnceLock<Result<PathBuf, String>>,
}

impl<'a> Runner<'a> {
    pub fn new(options: &'a LlmOptions, cancel: &'a Cancel) -> Runner<'a> {
        Runner { options, cancel, program: std::sync::OnceLock::new() }
    }

    /// The command's file name, for messages.
    fn name(&self) -> String {
        match &self.options.command {
            Some(c) => c.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| c.display().to_string()),
            None => self.options.tool.clone(),
        }
    }

    fn program(&self) -> Result<PathBuf, String> {
        self.program
            .get_or_init(|| match &self.options.command {
                // A path is run as it is; a bare name is looked up like the tools.
                Some(c) if c.components().count() > 1 || c.is_absolute() => Ok(c.clone()),
                Some(c) => crate::tools::find(&c.to_string_lossy(), None).ok_or_else(|| format!("{} was not found. The LLM pass was skipped.", c.display())),
                None => crate::tools::find(&self.options.tool, None).ok_or_else(|| {
                    format!(
                        "{tool} was not found (looked on the PATH and in the usual install locations). Install it, set tools.{tool} in the app's settings, or turn the LLM pass off. The LLM pass was skipped.",
                        tool = self.options.tool
                    )
                }),
            })
            .clone()
    }

    /// The reply text of one call.
    pub fn call(&self, prompt: &str) -> Result<String, CallError> {
        if self.cancel.is_cancelled() {
            return Err(CallError::Cancelled);
        }
        let program = self.program().map_err(CallError::Unavailable)?;
        let name = self.name();
        let dir = CallDir::new().map_err(|e| CallError::Failed(format!("could not make a directory for {name}: {e}")))?;
        let last_message = dir.0.join("last-message.txt");
        let codex = self.options.tool == "codex";
        let mut args: Vec<String> = if codex {
            ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never", "--output-last-message"]
                .iter()
                .map(|s| s.to_string())
                .chain([last_message.to_string_lossy().to_string()])
                .collect()
        } else {
            ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence"].iter().map(|s| s.to_string()).collect()
        };
        if let Some(model) = &self.options.model {
            args.push("--model".to_string());
            args.push(model.clone());
        }
        if codex {
            args.push("-".to_string());
        }
        let timeout = Duration::from_secs(self.options.timeout_secs.max(1));
        let output = match run(&program, &args, prompt.as_bytes(), &dir.0, timeout, self.cancel) {
            Ok(o) => o,
            Err(e) => return Err(CallError::Unavailable(format!("Could not run {}: {e}. The LLM pass was skipped.", program.display()))),
        };
        if self.cancel.is_cancelled() {
            return Err(CallError::Cancelled);
        }
        if output.timed_out {
            return Err(CallError::Failed(format!("{name} did not answer within {} seconds", timeout.as_secs())));
        }
        let code = output.status.and_then(|s| s.code());
        if code == Some(127) {
            return Err(CallError::Unavailable(format!("{name} could not start what it runs (exit status 127). The LLM pass was skipped.")));
        }
        if code != Some(0) {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let tail: String = stderr.chars().rev().take(300).collect::<Vec<_>>().into_iter().rev().collect();
            let status = code.map(|c| c.to_string()).unwrap_or_else(|| "a signal".to_string());
            return Err(CallError::Failed(format!("{name} exited with {status}: {tail}")));
        }
        if codex {
            return std::fs::read_to_string(&last_message).map_err(|_| CallError::Failed("codex wrote no last message".to_string()));
        }
        // claude -p --output-format json prints one result object; its `result` holds the reply text.
        let text = String::from_utf8_lossy(&output.stdout).to_string();
        if let Ok(serde_json::Value::Object(obj)) = serde_json::from_str::<serde_json::Value>(text.trim()) {
            if let Some(serde_json::Value::String(result)) = obj.get("result") {
                if obj.get("is_error").and_then(|v| v.as_bool()) == Some(true) {
                    let head: String = result.chars().take(300).collect();
                    return Err(CallError::Failed(format!("claude reported an error: {head}")));
                }
                return Ok(result.clone());
            }
        }
        Ok(text)
    }
}

/// The JSON object in a reply: from its first `{` to its last `}`, so prose or a code fence around it is fine.
pub(crate) fn parse_json<T: serde::de::DeserializeOwned>(text: &str) -> Result<T, String> {
    let (Some(start), Some(end)) = (text.find('{'), text.rfind('}')) else {
        return Err("reply has no JSON object".to_string());
    };
    if start >= end {
        return Err("reply has no JSON object".to_string());
    }
    serde_json::from_str(&text[start..=end]).map_err(|e| {
        if e.is_syntax() || e.is_eof() {
            "reply is not valid JSON".to_string()
        } else {
            e.to_string()
        }
    })
}

/// An error for one-line text: empty, more than one line, or too long.
pub(crate) fn check_text(s: &str, what: &str, max: usize) -> Vec<String> {
    let t = s.trim();
    if t.is_empty() {
        return vec![format!("{what} is empty")];
    }
    if t.contains('\n') {
        return vec![format!("{what} is more than one line")];
    }
    if t.chars().count() > max {
        return vec![format!("{what} is longer than {max} characters")];
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(serde::Deserialize, Debug, PartialEq)]
    struct Small {
        a: u32,
    }

    #[test]
    fn finds_the_object_in_prose() {
        assert_eq!(parse_json::<Small>("Here it is:\n```json\n{\"a\": 1}\n```\n"), Ok(Small { a: 1 }));
        assert_eq!(parse_json::<Small>("no object"), Err("reply has no JSON object".to_string()));
        assert_eq!(parse_json::<Small>("{\"a\": "), Err("reply has no JSON object".to_string()));
        assert_eq!(parse_json::<Small>("{\"a\": }"), Err("reply is not valid JSON".to_string()));
        assert!(parse_json::<Small>("{\"a\": null}").unwrap_err().contains("null"));
        assert!(parse_json::<Small>("{\"b\": 1}").unwrap_err().contains("missing field `a`"));
    }

    #[test]
    fn checks_one_line_text() {
        assert!(check_text("Loads the cart.", "summary", 200).is_empty());
        assert_eq!(check_text("  ", "summary", 200), vec!["summary is empty".to_string()]);
        assert_eq!(check_text("one\ntwo", "summary", 200), vec!["summary is more than one line".to_string()]);
        assert_eq!(check_text("abcdef", "summary", 5), vec!["summary is longer than 5 characters".to_string()]);
    }

    #[test]
    fn stops_a_call_that_runs_too_long() {
        let dir = CallDir::new().unwrap();
        let started = Instant::now();
        let out = run(Path::new("/bin/sleep"), &["30".to_string()], b"", &dir.0, Duration::from_millis(200), &Cancel::new()).unwrap();
        assert!(out.timed_out);
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[test]
    fn passes_a_large_prompt_through() {
        let dir = CallDir::new().unwrap();
        let prompt = "x".repeat(1_000_000);
        let out = run(Path::new("/bin/cat"), &[], prompt.as_bytes(), &dir.0, Duration::from_secs(30), &Cancel::new()).unwrap();
        assert_eq!(out.stdout.len(), prompt.len());
    }
}
