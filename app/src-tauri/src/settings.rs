//! The app's settings and recent reviews, in its data directory (`settings.json`), which a person may
//! edit by hand:
//!
//! ```json
//! {
//!   "editor": "xcode",                         // or vscode, cursor, zed, idea, studio, or "cmd {file}:{line}"
//!   "tools": { "bazel": "/opt/homebrew/bin/bazelisk", "java": "/path/to/jdk/bin/java",
//!              "node": "/path/to/node/bin/node", "yarn": "/path/to/yarn" },  // npx and corepack come from node's directory
//!   "cacheLimitGb": 30,                        // syntax, index, and Bazel action caches together
//!   "idleWorkspaceDays": 30,                   // app-owned Bazel workspaces of repositories unused this long are removed
//!   "llm": { "tool": "claude", "model": "sonnet" }  // the LLM pass for every review; off when missing
//! }
//! ```
//!
//! `llm` takes the fields of `reviewmap_core::llm::LlmOptions`: `tool` ("claude" or "codex"), and optionally
//! `command` (an executable to run instead, such as scripts/fake-llm.sh), `model`, `jobs`, `timeoutSecs`,
//! `structuralReview`, and `pullRequest`. `reviewmap --llm …` and `--no-llm` override it for one review.

use reviewmap_core::llm::LlmOptions;
use reviewmap_core::session::ReviewRequest;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Recent {
    pub repo: String,
    pub base: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(default)]
    pub targets: Vec<String>,
    #[serde(default)]
    pub bazel_args: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub editor: Option<String>,
    /// Absolute paths of tools, by name, for when they are not where the app looks.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub tools: BTreeMap<String, PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_limit_gb: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_workspace_days: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recent: Vec<Recent>,
    /// The LLM pass to run on every review. None: off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub llm: Option<LlmOptions>,
}

impl Settings {
    pub fn cache_limit_bytes(&self) -> u64 {
        (self.cache_limit_gb.unwrap_or(30.0).max(1.0) * 1024.0 * 1024.0 * 1024.0) as u64
    }

    pub fn idle_workspace_days(&self) -> u64 {
        self.idle_workspace_days.unwrap_or(30).max(1)
    }
}

fn path() -> PathBuf {
    reviewmap_core::store::data_root().join("settings.json")
}

pub fn load() -> Settings {
    std::fs::read(path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
}

fn save(settings: &Settings) {
    let path = path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(data) = serde_json::to_vec_pretty(settings) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, data).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}

/// Tells the core where the configured tools are.
pub fn apply(settings: &Settings) {
    reviewmap_core::tools::set_configured(settings.tools.clone());
}

/// Puts a review at the top of the recent list.
pub fn remember(request: &ReviewRequest) {
    let mut settings = load();
    let entry = Recent {
        repo: request.repo.to_string_lossy().to_string(),
        base: request.base.clone(),
        head: request.head.clone(),
        targets: request.targets.clone(),
        bazel_args: request.bazel_args.clone(),
    };
    settings.recent.retain(|r| !(r.repo == entry.repo && r.base == entry.base && r.head == entry.head));
    settings.recent.insert(0, entry);
    settings.recent.truncate(10);
    save(&settings);
}
