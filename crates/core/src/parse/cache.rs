//! The syntax cache: parse results by content, language, and parser version, so a file is parsed once
//! however many reviews, sides, and revisions contain it. It is disposable; an empty cache only costs time.

use super::ParsedFile;
use std::path::PathBuf;

pub struct SyntaxCache {
    dir: PathBuf,
}

impl SyntaxCache {
    /// `version` names the parser and its version; it becomes a directory, so results of another version are never read.
    pub fn new(language: &str, version: &str) -> SyntaxCache {
        let dir = crate::store::cache_root().join("syntax").join(language).join(crate::git::slug(version));
        SyntaxCache { dir }
    }

    fn path(&self, oid: &str) -> PathBuf {
        let (a, b) = oid.split_at(oid.len().min(2));
        self.dir.join(a).join(format!("{b}.json"))
    }

    pub fn get(&self, oid: &str) -> Option<ParsedFile> {
        let data = std::fs::read(self.path(oid)).ok()?;
        serde_json::from_slice(&data).ok()
    }

    pub fn put(&self, oid: &str, file: &ParsedFile) {
        let path = self.path(oid);
        let Some(dir) = path.parent() else { return };
        if std::fs::create_dir_all(dir).is_err() {
            return;
        }
        let Ok(data) = serde_json::to_vec(file) else { return };
        // Written under another name first, so a reader never sees half a file.
        let tmp = path.with_extension(format!("tmp{}", std::process::id()));
        if std::fs::write(&tmp, data).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}
