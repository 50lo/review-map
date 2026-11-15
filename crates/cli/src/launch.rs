//! Finding the app and handing it a review.
//!
//! The app is started by running its executable with the review as arguments. A second start of an app
//! that is already running is passed to the running instance, which focuses its window and starts the
//! review; the second process then exits. Started this way from a terminal, the app also inherits the
//! shell's PATH, which a Finder launch doesn't have.

use anyhow::{anyhow, Context, Result};
use reviewmap_core::session::ReviewRequest;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

const APP_NAME: &str = "Review Map.app";
const APP_BINARY: &str = "reviewmap-app";

/// The app's executable: `REVIEWMAP_APP` (an app bundle or an executable), an installed bundle, or Bazel's
/// build of the app next to this command's (`bazel-bin/app`, two levels up from `bazel-bin/crates/cli`).
fn app_executable() -> Result<PathBuf> {
    let in_bundle = |bundle: PathBuf| bundle.join("Contents/MacOS").join(APP_BINARY);
    if let Ok(given) = std::env::var("REVIEWMAP_APP") {
        if !given.is_empty() {
            let p = PathBuf::from(&given);
            let exe = if p.is_dir() { in_bundle(p) } else { p };
            if exe.is_file() {
                return Ok(exe);
            }
            return Err(anyhow!("REVIEWMAP_APP ({given}) is not the Review Map app or its executable."));
        }
    }
    let mut candidates: Vec<PathBuf> = Vec::new();
    let mut unbundled: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        let exe = std::fs::canonicalize(&exe).unwrap_or(exe);
        if let Some(dir) = exe.parent() {
            if dir.ends_with("Contents/MacOS") {
                // This command inside the bundle.
                candidates.push(dir.join(APP_BINARY));
            } else {
                unbundled.push(dir.join(APP_BINARY));
            }
            // Installed next to each other.
            candidates.push(in_bundle(dir.join("..").join(APP_NAME)));
            candidates.push(in_bundle(dir.join("../share/reviewmap").join(APP_NAME)));
            // Built by Bazel in the same configuration (//app:bundle and //app/src-tauri:reviewmap-app).
            let bazel_bin = dir.join("../..");
            candidates.push(in_bundle(bazel_bin.join("app").join(APP_NAME)));
            unbundled.push(bazel_bin.join("app/src-tauri").join(APP_BINARY));
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        candidates.push(in_bundle(PathBuf::from(home).join("Applications").join(APP_NAME)));
    }
    candidates.push(in_bundle(PathBuf::from("/Applications").join(APP_NAME)));
    // The executable outside a bundle runs too, without the app's name and icon; it comes last.
    candidates.extend(unbundled);
    candidates
        .into_iter()
        .find(|p| p.is_file())
        .ok_or_else(|| anyhow!("Can't find the Review Map app. Build it with scripts/build-app.sh, or set REVIEWMAP_APP to the app bundle."))
}

pub fn open_app(request: &ReviewRequest) -> Result<()> {
    let exe = app_executable()?;
    let mut command = Command::new(&exe);
    command.arg("--repo").arg(&request.repo).arg("--base").arg(&request.base);
    if let Some(head) = &request.head {
        command.arg("--head").arg(head);
    }
    if !request.use_merge_base {
        command.arg("--no-merge-base");
    }
    if let Some(cwd) = &request.cwd {
        command.arg("--cwd").arg(cwd);
    }
    for t in &request.targets {
        command.arg("--target").arg(t);
    }
    for a in &request.bazel_args {
        command.arg(format!("--bazel-arg={a}"));
    }
    match request.index {
        Some(false) => {
            command.arg("--no-index");
        }
        Some(true) => {
            command.arg("--index");
        }
        None => {}
    }
    // Detached from this terminal: the app outlives the command, and closing the terminal doesn't end it.
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
    command.spawn().with_context(|| format!("could not start {}", exe.display()))?;
    Ok(())
}
