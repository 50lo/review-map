//! Read-only access to the reviewed repository through gix. Nothing here writes to the repository,
//! its index, its refs, or `.git` (CORE-002): committed content is read from the object database, and
//! trees that a tool needs on disk are materialized into app-owned directories (see `bazel::workspace`).

use anyhow::{anyhow, bail, Context, Result};
use gix::ObjectId;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// What a tree entry is, for materializing it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryMode {
    File,
    Executable,
    Symlink,
    /// A submodule: its commit is recorded, its content is not in this repository.
    Submodule,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TreeEntry {
    pub oid: ObjectId,
    pub mode: EntryMode,
}

/// Every file of a commit, by repo-relative path.
pub type Tree = BTreeMap<String, TreeEntry>;

#[derive(Clone)]
pub struct Repo {
    inner: Arc<gix::ThreadSafeRepository>,
    root: PathBuf,
}

impl Repo {
    /// Opens the repository that contains `path` (any directory inside it).
    pub fn discover(path: &Path) -> Result<Repo> {
        let repo = gix::discover(path).with_context(|| format!("{} is not inside a git repository", path.display()))?;
        let root = repo
            .workdir()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| repo.git_dir().to_path_buf());
        let root = std::fs::canonicalize(&root).unwrap_or(root);
        Ok(Repo { inner: Arc::new(repo.into_sync()), root })
    }

    /// The working directory of the repository (the git directory for a bare one).
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// A handle for the calling thread. gix repositories are cheap to clone per thread and not shareable.
    pub fn local(&self) -> gix::Repository {
        let mut repo = self.inner.to_thread_local();
        repo.object_cache_size_if_unset(32 * 1024 * 1024);
        repo
    }

    /// The commit a ref, tag, or sha names.
    pub fn resolve(&self, rev: &str) -> Result<ObjectId> {
        let repo = self.local();
        let spec = format!("{rev}^{{commit}}");
        let id = repo
            .rev_parse_single(spec.as_str())
            .map_err(|e| anyhow!("{rev} does not name a commit in {}: {e}", self.root.display()))?;
        Ok(id.detach())
    }

    /// The merge-base of two commits, or None when they share no history.
    pub fn merge_base(&self, a: ObjectId, b: ObjectId) -> Result<Option<ObjectId>> {
        let repo = self.local();
        match repo.merge_base(a, b) {
            Ok(id) => Ok(id.map(|id| id.detach())),
            Err(e) => {
                let text = e.to_string();
                if text.to_lowercase().contains("no merge base") || text.to_lowercase().contains("not found") {
                    Ok(None)
                } else {
                    Err(anyhow!("could not find the merge-base: {text}"))
                }
            }
        }
    }

    /// The branch checked out in the repository, or "HEAD" when it is detached or can't be read.
    pub fn current_branch(&self) -> String {
        let repo = self.local();
        match repo.head_name() {
            Ok(Some(name)) => name.shorten().to_string(),
            _ => "HEAD".to_string(),
        }
    }

    /// Every file in the commit's tree.
    pub fn tree(&self, commit: ObjectId) -> Result<Tree> {
        let repo = self.local();
        let commit = repo.find_commit(commit)?;
        let tree = commit.tree()?;
        let mut recorder = gix::traverse::tree::Recorder::default();
        tree.traverse().breadthfirst(&mut recorder)?;
        let mut out = Tree::new();
        for entry in recorder.records {
            let mode = if entry.mode.is_tree() {
                continue;
            } else if entry.mode.is_commit() {
                EntryMode::Submodule
            } else if entry.mode.is_link() {
                EntryMode::Symlink
            } else if entry.mode.is_executable() {
                EntryMode::Executable
            } else {
                EntryMode::File
            };
            out.insert(entry.filepath.to_string(), TreeEntry { oid: entry.oid, mode });
        }
        Ok(out)
    }

    /// The content of a blob.
    pub fn blob(&self, oid: ObjectId) -> Result<Vec<u8>> {
        read_blob(&self.local(), oid)
    }

    /// The content of a file in a commit, or None when the commit doesn't have it.
    pub fn read_path(&self, commit: ObjectId, path: &str) -> Result<Option<Vec<u8>>> {
        let repo = self.local();
        let tree = repo.find_commit(commit)?.tree()?;
        match tree.lookup_entry_by_path(path)? {
            Some(entry) if entry.mode().is_blob() || entry.mode().is_link() => Ok(Some(entry.object()?.data.clone())),
            _ => Ok(None),
        }
    }

    /// The subject lines of the commits in `base..head`, newest first, up to `limit`.
    pub fn commit_subjects(&self, base: ObjectId, head: ObjectId, limit: usize) -> Vec<String> {
        let repo = self.local();
        let mut out = Vec::new();
        let Ok(walk) = repo.rev_walk([head]).with_hidden([base]).all() else { return out };
        for info in walk.flatten().take(limit) {
            if let Ok(commit) = info.object() {
                if let Ok(message) = commit.message() {
                    out.push(message.title.to_string().trim().to_string());
                }
            }
        }
        out
    }
}

/// The content of a blob, read with a thread's own repository handle.
pub fn read_blob(repo: &gix::Repository, oid: ObjectId) -> Result<Vec<u8>> {
    let object = repo.find_object(oid)?;
    if object.kind != gix::object::Kind::Blob {
        bail!("{oid} is not a blob");
    }
    Ok(object.data.clone())
}

/// A blob as text. Invalid UTF-8 is replaced, as the prototype's readers did for source files.
pub fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// "feature/login" becomes "feature-login"; anything outside letters, digits, dot, dash, and underscore becomes a dash.
pub fn slug(s: &str) -> String {
    let out: String = s
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' { c } else { '-' })
        .collect();
    if out.is_empty() || out.chars().all(|c| c == '.') {
        "-".to_string()
    } else {
        out
    }
}
