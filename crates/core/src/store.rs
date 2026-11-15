//! Where the app keeps its files.
//!
//! Disposable analysis and build data (syntax cache, indexes, tools, Bazel workspaces and output bases)
//! lives under the cache root; notes, reviewed marks, and settings live under the data root, so clearing
//! the cache never loses a review. `REVIEWMAP_HOME` moves both under one directory (tests use it).

use std::path::PathBuf;

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"))
}

/// Disposable data: `~/Library/Caches/reviewmap`, or `$REVIEWMAP_HOME/cache`.
pub fn cache_root() -> PathBuf {
    match std::env::var_os("REVIEWMAP_HOME") {
        Some(h) if !h.is_empty() => PathBuf::from(h).join("cache"),
        _ => home().join("Library/Caches/reviewmap"),
    }
}

/// Durable data: `~/Library/Application Support/reviewmap`, or `$REVIEWMAP_HOME/data`.
pub fn data_root() -> PathBuf {
    match std::env::var_os("REVIEWMAP_HOME") {
        Some(h) if !h.is_empty() => PathBuf::from(h).join("data"),
        _ => home().join("Library/Application Support/reviewmap"),
    }
}

/// A stable directory name for a repository: its folder name and a short hash of its full path, so two
/// checkouts with the same name stay apart.
pub fn repo_key(root: &std::path::Path) -> String {
    use sha2::{Digest, Sha256};
    let name = root.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "repo".to_string());
    let digest = Sha256::digest(root.to_string_lossy().as_bytes());
    format!("{}-{}", crate::git::slug(&name), hex(&digest[..4]))
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// SHA-256 of some text parts, as hex, for cache keys.
pub fn digest<I, S>(parts: I) -> String
where
    I: IntoIterator<Item = S>,
    S: AsRef<[u8]>,
{
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    for p in parts {
        let p = p.as_ref();
        hasher.update((p.len() as u64).to_le_bytes());
        hasher.update(p);
    }
    hex(&hasher.finalize())
}

/// Keeps a cache directory under a size: the least recently used files go first. Returns the bytes removed.
/// Only call it for directories whose files can be made again, and not while a job is writing to them.
pub fn evict_lru(dir: &std::path::Path, max_bytes: u64) -> u64 {
    let mut files: Vec<(std::time::SystemTime, u64, PathBuf)> = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                stack.push(entry.path());
            } else if meta.is_file() {
                // Reading a cache entry doesn't always update its access time, so the newer of the two counts.
                let used = meta.accessed().ok().into_iter().chain(meta.modified().ok()).max().unwrap_or(std::time::UNIX_EPOCH);
                files.push((used, meta.len(), entry.path()));
            }
        }
    }
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    if total <= max_bytes {
        return 0;
    }
    files.sort();
    let mut removed = 0;
    for (_, size, path) in files {
        if total <= max_bytes {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            total -= size;
            removed += size;
        }
    }
    removed
}

/// Removes the app-owned Bazel workspaces of repositories that no review has used for `days`. Their output
/// bases are the largest thing the app keeps, and nothing in them is needed to review another repository.
pub fn evict_idle_workspaces(days: u64) {
    let root = cache_root().join("bazel");
    let Ok(entries) = std::fs::read_dir(&root) else { return };
    let limit = std::time::Duration::from_secs(days * 24 * 3600);
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.join("lock").is_file() {
            continue;
        }
        let idle = std::fs::metadata(path.join("lock")).and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).map(|e| e > limit).unwrap_or(false);
        if !idle {
            continue;
        }
        // A workspace another instance is using stays.
        let Ok(lock) = std::fs::File::options().write(true).open(path.join("lock")) else { continue };
        if lock.try_lock().is_err() {
            continue;
        }
        // Bazel marks some of its outputs read-only.
        let _ = std::process::Command::new("/bin/chmod").arg("-R").arg("u+w").arg(&path).status();
        let _ = std::fs::remove_dir_all(&path);
    }
}

/// The cache limit applied at startup: the syntax cache, the index cache, and Bazel's shared action cache
/// share `limit_bytes` in fixed proportions.
pub fn evict(limit_bytes: u64, idle_days: u64) {
    let root = cache_root();
    evict_lru(&root.join("syntax"), limit_bytes / 10);
    evict_lru(&root.join("index"), limit_bytes / 5);
    evict_lru(&root.join("bazel").join("disk-cache"), limit_bytes / 10 * 7);
    evict_idle_workspaces(idle_days);
}
