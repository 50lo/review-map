//! App-owned, reusable source trees for Bazel.
//!
//! A historical revision needs a real source tree, and gix alone cannot give Bazel one. For each reviewed
//! repository the app keeps one base and one head directory outside that repository, at stable paths, and
//! each nested Bazel workspace in them gets its own output base:
//!
//! ```text
//! <cache>/bazel/<repo>/lock
//! <cache>/bazel/<repo>/<side>/tree/…            the revision's files (the workspace is a subdirectory)
//! <cache>/bazel/<repo>/<side>/manifest.json     what `tree` holds, for the next update
//! <cache>/bazel/<repo>/<side>/out/<workspace>/  that workspace's output base
//! <cache>/bazel/disk-cache/                     action cache shared by every workspace
//! ```
//!
//! A directory is updated to the requested revision only between jobs, under an exclusive lock, by
//! rewriting the files that differ and removing the ones that are gone; untouched files keep their
//! timestamps, so Bazel's own caches stay warm. Output bases are kept across reviews and across launches;
//! the Bazel servers that own them are shut down when the app exits (see `shutdown_all`).

use crate::git::{read_blob, EntryMode, Repo, Tree};
use crate::model::Side;
use crate::proc::{Cancel, Cmd, Log};
use anyhow::{anyhow, Context, Result};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Serialize, Deserialize, Default)]
struct Manifest {
    /// The commit the tree was last brought to, or "partial" after an interrupted update.
    sha: String,
    /// path -> (blob id, mode)
    entries: BTreeMap<String, (String, u8)>,
}

fn mode_code(mode: EntryMode) -> u8 {
    match mode {
        EntryMode::File => 0,
        EntryMode::Executable => 1,
        EntryMode::Symlink => 2,
        EntryMode::Submodule => 3,
    }
}

/// The app-owned directories of one reviewed repository, held under an exclusive lock.
pub struct Workspaces {
    root: PathBuf,
    _lock: File,
}

/// Output bases whose Bazel servers this process started, to shut down at exit.
static OUTPUT_BASES: Mutex<BTreeSet<(PathBuf, PathBuf, PathBuf)>> = Mutex::new(BTreeSet::new());

impl Workspaces {
    /// Takes the repository's lock, waiting while another job (or another instance of the app) holds it.
    pub fn acquire(repo_root: &Path, cancel: &Cancel) -> Result<Workspaces> {
        let root = crate::store::cache_root().join("bazel").join(crate::store::repo_key(repo_root));
        std::fs::create_dir_all(&root)?;
        let lock = File::options().create(true).truncate(false).write(true).open(root.join("lock"))?;
        loop {
            match lock.try_lock() {
                Ok(()) => break,
                Err(std::fs::TryLockError::WouldBlock) => {
                    cancel.check()?;
                    std::thread::sleep(std::time::Duration::from_millis(200));
                }
                Err(std::fs::TryLockError::Error(e)) => return Err(anyhow!("could not lock {}: {e}", root.display())),
            }
        }
        // The lock's timestamp says when the repository was last reviewed, for clearing idle workspaces.
        let _ = lock.set_modified(std::time::SystemTime::now());
        Ok(Workspaces { root, _lock: lock })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The directory that holds a side's revision.
    pub fn tree_dir(&self, side: Side) -> PathBuf {
        self.root.join(side.name()).join("tree")
    }

    /// The directory of a nested workspace inside a side's tree.
    pub fn workspace_dir(&self, side: Side, workspace: &str) -> PathBuf {
        let tree = self.tree_dir(side);
        if workspace.is_empty() {
            tree
        } else {
            tree.join(workspace)
        }
    }

    /// The dedicated output base of a nested workspace at one side.
    pub fn output_base(&self, side: Side, workspace: &str) -> PathBuf {
        let name = if workspace.is_empty() { "_root".to_string() } else { crate::git::slug(&workspace.replace('/', "__")) };
        self.root.join(side.name()).join("out").join(name)
    }

    /// The action cache shared by every app-owned workspace.
    pub fn disk_cache() -> PathBuf {
        crate::store::cache_root().join("bazel").join("disk-cache")
    }

    /// Brings a side's directory to a revision: writes the files that differ from what the directory holds,
    /// removes the ones the revision doesn't have, and leaves the rest untouched. Returns the directory.
    pub fn materialize(&self, repo: &Repo, side: Side, tree: &Tree, sha: &str, cancel: &Cancel, progress: Log) -> Result<PathBuf> {
        let dir = self.tree_dir(side);
        let manifest_path = self.root.join(side.name()).join("manifest.json");
        let mut manifest: Manifest = std::fs::read(&manifest_path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        if manifest.entries.is_empty() && dir.exists() {
            // Unknown contents: start over rather than trust them.
            std::fs::remove_dir_all(&dir).with_context(|| format!("could not clear {}", dir.display()))?;
        }
        std::fs::create_dir_all(&dir)?;
        if manifest.sha == sha {
            return Ok(dir);
        }

        let wanted: BTreeMap<&String, (String, u8)> = tree.iter().map(|(p, e)| (p, (e.oid.to_string(), mode_code(e.mode)))).collect();
        let obsolete: Vec<String> = manifest.entries.keys().filter(|p| !wanted.contains_key(p)).cloned().collect();
        let changed: Vec<&String> = wanted.iter().filter(|(p, v)| manifest.entries.get(**p) != Some(*v)).map(|(p, _)| *p).collect();
        progress(format!(
            "Updating the {} workspace to {}: {} file{} to write, {} to remove",
            side.name(),
            &sha[..sha.len().min(8)],
            changed.len(),
            if changed.len() == 1 { "" } else { "s" },
            obsolete.len()
        ));

        // The manifest must describe the directory even when the update stops halfway.
        manifest.sha = "partial".to_string();
        let save = |m: &Manifest| -> Result<()> {
            let tmp = manifest_path.with_extension("json.tmp");
            std::fs::write(&tmp, serde_json::to_vec(m)?)?;
            std::fs::rename(&tmp, &manifest_path)?;
            Ok(())
        };
        save(&manifest)?;

        for path in &obsolete {
            let full = dir.join(path);
            let _ = std::fs::remove_file(&full);
            // Directories that the removal emptied go too, so Bazel doesn't see stale packages.
            let mut parent = full.parent();
            while let Some(p) = parent {
                if p == dir || std::fs::remove_dir(p).is_err() {
                    break;
                }
                parent = p.parent();
            }
            manifest.entries.remove(path);
        }

        let written: Mutex<Vec<(String, (String, u8))>> = Mutex::new(Vec::new());
        let result: Result<()> = changed.par_chunks(64).try_for_each_init(
            || repo.local(),
            |local, chunk| -> Result<()> {
                cancel.check()?;
                let mut done = Vec::with_capacity(chunk.len());
                for path in chunk {
                    let entry = &tree[*path];
                    let full = dir.join(path);
                    if let Some(parent) = full.parent() {
                        std::fs::create_dir_all(parent)?;
                    }
                    // Whatever is there (a file where a link goes, a directory where a file goes) makes way.
                    if let Ok(meta) = std::fs::symlink_metadata(&full) {
                        if meta.is_dir() {
                            let _ = std::fs::remove_dir_all(&full);
                        } else {
                            let _ = std::fs::remove_file(&full);
                        }
                    }
                    match entry.mode {
                        EntryMode::Submodule => {
                            std::fs::create_dir_all(&full)?;
                        }
                        EntryMode::Symlink => {
                            let target = read_blob(local, entry.oid)?;
                            std::os::unix::fs::symlink(String::from_utf8_lossy(&target).as_ref(), &full)
                                .with_context(|| format!("could not link {}", full.display()))?;
                        }
                        EntryMode::File | EntryMode::Executable => {
                            let data = read_blob(local, entry.oid)?;
                            std::fs::write(&full, data).with_context(|| format!("could not write {}", full.display()))?;
                            if entry.mode == EntryMode::Executable {
                                use std::os::unix::fs::PermissionsExt;
                                std::fs::set_permissions(&full, std::fs::Permissions::from_mode(0o755))?;
                            }
                        }
                    }
                    done.push(((*path).clone(), (entry.oid.to_string(), mode_code(entry.mode))));
                }
                written.lock().unwrap().extend(done);
                Ok(())
            },
        );
        for (path, value) in written.into_inner().unwrap() {
            manifest.entries.insert(path, value);
        }
        if result.is_ok() {
            manifest.sha = sha.to_string();
        }
        save(&manifest)?;
        result?;
        Ok(dir)
    }
}

/// How to call Bazel for one workspace at one side.
#[derive(Clone, Debug)]
pub struct BazelEnv {
    pub bazel: PathBuf,
    /// The workspace directory inside the app-owned tree.
    pub dir: PathBuf,
    pub output_base: PathBuf,
    /// Extra arguments for queries and builds, such as a config.
    pub args: Vec<String>,
}

impl BazelEnv {
    pub fn new(bazel: PathBuf, dir: PathBuf, output_base: PathBuf, args: Vec<String>) -> BazelEnv {
        OUTPUT_BASES.lock().unwrap().insert((bazel.clone(), dir.clone(), output_base.clone()));
        BazelEnv { bazel, dir, output_base, args }
    }

    /// A Bazel command in this workspace: `bazel --output_base=… <command>`. The server stays up between
    /// commands of a session (its analysis cache makes the next query or build faster) and idles out after
    /// fifteen minutes if the app is killed before it can shut it down.
    pub fn command(&self, command: &str) -> Cmd {
        Cmd::new(&self.bazel)
            .arg(format!("--output_base={}", self.output_base.display()))
            .arg("--max_idle_secs=900")
            .arg(command)
            .cwd(&self.dir)
            .context(self.side_name())
            .context(format!("workspace {:?}", self.workspace_name()))
    }

    /// The side this environment builds, from its output base (`<root>/<side>/out/<name>`), for `[timing]` lines.
    fn side_name(&self) -> String {
        self.output_base.parent().and_then(Path::parent).and_then(Path::file_name).map(|n| n.to_string_lossy().to_string()).unwrap_or_default()
    }

    /// The workspace's path in the repository (empty for the root), from its directory in the side's tree.
    fn workspace_name(&self) -> String {
        let tree = self.output_base.parent().and_then(Path::parent).map(|side| side.join("tree"));
        match tree.as_deref().and_then(|t| self.dir.strip_prefix(t).ok()) {
            Some(rel) => rel.to_string_lossy().to_string(),
            None => self.output_base.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
        }
    }

    /// `bazel info` values by key.
    pub fn info(&self, keys: &[&str], cancel: &Cancel) -> Result<BTreeMap<String, String>> {
        let out = self.command("info").args(keys.iter().copied()).args(self.args.iter().cloned()).output_string(cancel)?;
        let mut values = BTreeMap::new();
        if keys.len() == 1 {
            values.insert(keys[0].to_string(), out.trim().to_string());
            return Ok(values);
        }
        for line in out.lines() {
            if let Some((k, v)) = line.split_once(':') {
                values.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
        Ok(values)
    }
}

/// Stops the Bazel servers this process started. Output bases stay on disk; the servers' in-memory
/// analysis state is lost, so reopening the app is slower than another review in the same session.
pub fn shutdown_all() {
    let bases: Vec<(PathBuf, PathBuf, PathBuf)> = std::mem::take(&mut *OUTPUT_BASES.lock().unwrap())
        .into_iter()
        .filter(|(_, dir, base)| base.join("server").exists() && dir.exists())
        .collect();
    if bases.is_empty() {
        return;
    }
    let _timer = crate::proc::timer(format!("shutdown bazel servers ({})", bases.len()));
    let handles: Vec<_> = bases
        .into_iter()
        .map(|(bazel, dir, base)| {
            std::thread::spawn(move || {
                let _ = crate::proc::spawn(
                    std::process::Command::new(&bazel)
                        .arg(format!("--output_base={}", base.display()))
                        .arg("shutdown")
                        .env("PATH", crate::tools::child_path())
                        .current_dir(&dir)
                        .stdin(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null()),
                )
                .and_then(|mut c| c.wait());
            })
        })
        .collect();
    for h in handles {
        let _ = h.join();
    }
}
