//! The client of `reviewmap-swift-helper` (see `helper/`): one long-lived process per job that parses
//! Swift with SwiftSyntax and reads index stores with IndexStoreDB. Requests and replies are JSON lines.

use super::ParsedFile;
use crate::index::IndexedRef;
use crate::proc::Cancel;
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

pub struct SwiftHelper {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
    /// Part of the syntax cache key.
    pub version: String,
}

/// A directory index paths may start with, and the repo-relative directory it stands for.
#[derive(Serialize, Clone, Debug)]
pub struct IndexRoot {
    pub path: String,
    pub prefix: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct IndexRequest {
    pub store_path: String,
    pub database_path: String,
    pub library_path: String,
    pub roots: Vec<IndexRoot>,
    /// The directory "." stands for in the store's paths (Bazel's execution root), when paths are remapped.
    pub prefix_map_root: Option<String>,
    pub files: Vec<String>,
}

#[derive(Deserialize)]
struct Reply {
    id: i64,
    #[serde(default)]
    done: bool,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    key: Option<String>,
    #[serde(default)]
    file: Option<ParsedFile>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    refs: Option<Vec<(u32, String, u32, String)>>,
}

impl SwiftHelper {
    /// The helper binary: `REVIEWMAP_SWIFT_HELPER`, next to the running executable (the app bundles it there),
    /// or Bazel's build of it next to the running executable's (`bazel-bin/helper`, two levels up from
    /// `bazel-bin/crates/cli/reviewmap` and `bazel-bin/app/src-tauri/reviewmap-app`).
    pub fn locate() -> Option<PathBuf> {
        if let Ok(p) = std::env::var("REVIEWMAP_SWIFT_HELPER") {
            if !p.is_empty() {
                return Some(PathBuf::from(p));
            }
        }
        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Ok(exe) = std::env::current_exe() {
            let exe = std::fs::canonicalize(&exe).unwrap_or(exe);
            if let Some(dir) = exe.parent() {
                candidates.push(dir.join("reviewmap-swift-helper"));
                candidates.push(dir.join("../Resources/reviewmap-swift-helper"));
                candidates.push(dir.join("../../helper/reviewmap-swift-helper"));
            }
        }
        candidates.into_iter().find(|p| p.is_file())
    }

    pub fn start() -> Result<SwiftHelper> {
        let path = Self::locate().ok_or_else(|| {
            anyhow!("The Swift helper is not built. Run `bazel build //helper:reviewmap-swift-helper`, or set REVIEWMAP_SWIFT_HELPER to its path.")
        })?;
        let mut child = crate::proc::spawn(Command::new(&path).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).env("PATH", crate::tools::child_path()).process_group(0))
            .with_context(|| format!("could not start {}", path.display()))?;
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::with_capacity(1 << 20, child.stdout.take().unwrap());
        let mut helper = SwiftHelper { child, stdin, stdout, next_id: 1, version: String::new() };
        let id = helper.send(&serde_json::json!({ "op": "version" }))?;
        loop {
            let reply = helper.read(id)?;
            if let Some(v) = reply.version {
                helper.version = v;
            }
            if reply.done {
                break;
            }
        }
        if helper.version.is_empty() {
            bail!("The Swift helper did not report its version.");
        }
        Ok(helper)
    }

    fn send(&mut self, body: &serde_json::Value) -> Result<i64> {
        let id = self.next_id as i64;
        self.next_id += 1;
        let mut object = body.clone();
        object["id"] = serde_json::json!(id);
        let mut line = serde_json::to_vec(&object)?;
        line.push(b'\n');
        self.stdin.write_all(&line).context("the Swift helper stopped")?;
        self.stdin.flush()?;
        Ok(id)
    }

    fn read(&mut self, id: i64) -> Result<Reply> {
        loop {
            let mut line = String::new();
            if self.stdout.read_line(&mut line)? == 0 {
                bail!("the Swift helper stopped before it answered");
            }
            if line.trim().is_empty() {
                continue;
            }
            let reply: Reply = serde_json::from_str(&line).context("the Swift helper sent a line that is not a reply")?;
            if reply.id == id || reply.id == -1 {
                return Ok(reply);
            }
        }
    }

    /// Parses a batch of files. `files` holds (key, path, source); `on_file` gets each key with its result.
    pub fn parse(&mut self, files: &[(String, String, String)], mut on_file: impl FnMut(String, ParsedFile)) -> Result<()> {
        if files.is_empty() {
            return Ok(());
        }
        let list: Vec<serde_json::Value> =
            files.iter().map(|(key, path, source)| serde_json::json!({ "key": key, "path": path, "source": source })).collect();
        let id = self.send(&serde_json::json!({ "op": "parse", "files": list }))?;
        loop {
            let reply = self.read(id)?;
            if let (Some(key), Some(file)) = (reply.key, reply.file) {
                on_file(key, file);
            }
            if reply.done {
                if let Some(e) = reply.error {
                    bail!("the Swift helper could not parse: {e}");
                }
                return Ok(());
            }
        }
    }

    /// Reads an index store: for each file with index data, its references.
    pub fn index(&mut self, request: &IndexRequest, cancel: &Cancel) -> Result<BTreeMap<String, Vec<IndexedRef>>> {
        cancel.check()?;
        let pid = self.child.id();
        // Importing a large store takes a while; cancelling stops the helper, and the job starts another when needed.
        cancel.register(pid);
        let result = (|| -> Result<BTreeMap<String, Vec<IndexedRef>>> {
            let id = self.send(&serde_json::json!({ "op": "index", "index": request }))?;
            let mut out = BTreeMap::new();
            loop {
                let reply = self.read(id)?;
                if let (Some(path), Some(refs)) = (reply.path, reply.refs) {
                    out.insert(
                        path,
                        refs.into_iter().map(|(line, target_file, target_line, name)| IndexedRef { line, target_file, target_line, name }).collect(),
                    );
                }
                if reply.done {
                    if let Some(e) = reply.error {
                        bail!("the index store could not be read: {e}");
                    }
                    return Ok(out);
                }
            }
        })();
        cancel.unregister(pid);
        cancel.check()?;
        result
    }
}

impl Drop for SwiftHelper {
    fn drop(&mut self) {
        // Closing stdin ends the helper's read loop; the kill covers a helper that is busy.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
