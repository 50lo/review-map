//! Finding the external tools the app runs (Bazel, a JDK, Xcode's tools, curl).
//!
//! A Finder launch has no shell PATH, so tools are looked up in this order: an environment override
//! (`REVIEWMAP_BAZEL`, …), an absolute path in the app's settings, the inherited PATH, and the usual
//! install locations. The shell is never asked for its environment: a login shell can stall startup.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// Absolute tool paths from the app's settings, by tool name ("bazel", "java").
static CONFIGURED: OnceLock<Mutex<BTreeMap<String, PathBuf>>> = OnceLock::new();

pub fn set_configured(tools: BTreeMap<String, PathBuf>) {
    *CONFIGURED.get_or_init(Default::default).lock().unwrap() = tools;
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

/// Directories where developer tools are usually installed, after the inherited PATH.
fn known_dirs() -> Vec<PathBuf> {
    let home = home();
    vec![
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        home.join(".local/bin"),
        home.join("bin"),
        home.join(".local/share/mise/shims"),
        home.join(".asdf/shims"),
        home.join(".cargo/bin"),
        PathBuf::from("/opt/homebrew/opt/openjdk/bin"),
        PathBuf::from("/usr/local/opt/openjdk/bin"),
        PathBuf::from("/usr/bin"),
        PathBuf::from("/bin"),
        PathBuf::from("/usr/sbin"),
        PathBuf::from("/sbin"),
    ]
}

fn search_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    for d in known_dirs() {
        if !dirs.contains(&d) {
            dirs.push(d);
        }
    }
    dirs
}

/// The PATH given to child processes: the inherited one, then the usual install locations, so that
/// tools started by tools (Bazel running git, xcrun, python) are found from a Finder launch too.
pub fn child_path() -> std::ffi::OsString {
    std::env::join_paths(search_dirs()).unwrap_or_else(|_| "/usr/bin:/bin".into())
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

/// An executable by name: `env_override` (an environment variable holding a path or a command name), the
/// settings, then the search directories.
pub fn find(name: &str, env_override: Option<&str>) -> Option<PathBuf> {
    if let Some(var) = env_override {
        if let Ok(value) = std::env::var(var) {
            if !value.is_empty() {
                let p = PathBuf::from(&value);
                if p.is_absolute() {
                    return is_executable(&p).then_some(p);
                }
                return search_dirs().into_iter().map(|d| d.join(&value)).find(|p| is_executable(p));
            }
        }
    }
    if let Some(p) = CONFIGURED.get().and_then(|m| m.lock().unwrap().get(name).cloned()) {
        if is_executable(&p) {
            return Some(p);
        }
    }
    search_dirs().into_iter().map(|d| d.join(name)).find(|p| is_executable(p))
}

/// Bazel: `REVIEWMAP_BAZEL`, else bazel, else bazelisk.
pub fn bazel() -> Option<PathBuf> {
    if std::env::var("REVIEWMAP_BAZEL").map(|v| !v.is_empty()).unwrap_or(false) {
        return find("bazel", Some("REVIEWMAP_BAZEL"));
    }
    find("bazel", None).or_else(|| find("bazelisk", None))
}

/// A `java` that runs. macOS has a stub at /usr/bin/java that exists without a JDK installed, so the
/// candidate is run once. `JAVA_HOME` wins when it is set.
pub fn java() -> Option<PathBuf> {
    static FOUND: OnceLock<Option<PathBuf>> = OnceLock::new();
    FOUND
        .get_or_init(|| {
            let mut candidates: Vec<PathBuf> = Vec::new();
            if let Ok(home) = std::env::var("JAVA_HOME") {
                if !home.is_empty() {
                    candidates.push(PathBuf::from(home).join("bin/java"));
                }
            }
            if let Some(p) = CONFIGURED.get().and_then(|m| m.lock().unwrap().get("java").cloned()) {
                candidates.push(p);
            }
            for dir in search_dirs() {
                candidates.push(dir.join("java"));
            }
            candidates.into_iter().find(|p| {
                is_executable(p)
                    && std::process::Command::new(p)
                        .arg("-version")
                        .stdin(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .status()
                        .map(|s| s.success())
                        .unwrap_or(false)
            })
        })
        .clone()
}

/// libIndexStore of the toolchain that builds: `REVIEWMAP_LIBINDEXSTORE`, or next to `swift`.
pub fn lib_index_store() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("REVIEWMAP_LIBINDEXSTORE") {
        if !p.is_empty() {
            return Some(PathBuf::from(p));
        }
    }
    let mut swift_paths: Vec<PathBuf> = Vec::new();
    if let Some(xcrun) = find("xcrun", None) {
        if let Ok(out) = std::process::Command::new(xcrun).args(["--find", "swift"]).output() {
            let p = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if out.status.success() && !p.is_empty() {
                swift_paths.push(PathBuf::from(p));
            }
        }
    }
    if let Some(p) = find("swift", None) {
        swift_paths.push(p);
    }
    for p in swift_paths {
        let real = std::fs::canonicalize(&p).unwrap_or(p);
        if let Some(lib) = real.parent().and_then(Path::parent).map(|d| d.join("lib")) {
            for name in ["libIndexStore.dylib", "libIndexStore.so"] {
                if lib.join(name).exists() {
                    return Some(lib.join(name));
                }
            }
        }
    }
    None
}
