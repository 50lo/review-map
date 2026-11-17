//! A cache of build graphs, so the same graph is not queried again.
//!
//! A workspace's graph depends on its build definitions, on which files exist (`glob()`), on the review
//! scope and Bazel arguments, and on the Bazel and Xcode it runs with. The key is a digest of all of those;
//! when in doubt an input is in it, because a miss costs one query and a wrong hit gives wrong components.
//! Head and base share keys: when a change leaves every input alone, base gets head's graph.
//!
//! ```text
//! <cache>/graphs/<repo key>/<key>.json   a WorkspaceGraph, from a complete query only
//! ```

use super::graph::WorkspaceGraph;
use super::query::{query_shape, Scope};
use crate::git::{EntryMode, Tree};
use crate::paths::{file_name, is_under};
use crate::proc::{Cancel, Cmd};
use anyhow::{anyhow, Result};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Bump when the stored value or the key changes meaning.
const FORMAT: &str = "graph-cache-v1";

/// The code that makes a graph from Bazel's answer. A change to it changes every key.
const GRAPH_CODE: &[&str] = &[include_str!("query.rs"), include_str!("graph.rs")];

/// Files that can change a workspace's graph: build definitions, Bazel's own configuration, and the
/// lockfiles and manifests that module extensions and repository rules read. Matched by name anywhere in
/// the repository, because a workspace can reach outside its directory (`local_path_override`).
pub fn affects_graph(path: &str) -> bool {
    let name = file_name(path);
    const NAMES: &[&str] = &[
        "WORKSPACE",
        ".bazelversion",
        ".bazelignore",
        ".bazeliskrc",
        "Cargo.lock",
        "Cargo.toml",
        "pnpm-lock.yaml",
        "pnpm-workspace.yaml",
        "package.json",
        "package-lock.json",
        "yarn.lock",
        ".npmrc",
        "Package.swift",
        "Package.resolved",
        "go.mod",
        "go.sum",
        "go.work",
    ];
    NAMES.contains(&name)
        || name.starts_with("BUILD")
        || name.ends_with(".bazel")
        || name.ends_with(".bzl")
        || name.contains("bazelrc")
        || name.ends_with(".lock")
        || name.ends_with(".patch")
        || name.ends_with("_install.json")
        || (name.starts_with("requirements") && name.ends_with(".txt"))
        || path == "tools/bazel"
        || path.ends_with("/tools/bazel")
}

fn mode_name(mode: EntryMode) -> &'static str {
    match mode {
        EntryMode::File => "f",
        EntryMode::Executable => "x",
        EntryMode::Symlink => "l",
        EntryMode::Submodule => "m",
    }
}

/// The cache key of one workspace's graph at one side. `environment` is what outside the tree the graph
/// depends on (`environment`).
pub fn graph_key(tree: &Tree, workspace: &str, scope: &Scope, bazel_args: &[String], environment: &str) -> String {
    let mut parts: Vec<String> = vec![FORMAT.to_string(), query_shape()];
    parts.push(crate::store::digest(GRAPH_CODE));
    parts.push(format!("workspace {workspace}"));
    parts.push(format!("scope {} {}", scope.kind, scope.targets.len()));
    parts.extend(scope.targets.iter().cloned());
    parts.push(format!("args {}", bazel_args.len()));
    parts.extend(bazel_args.iter().cloned());
    parts.push("environment".to_string());
    parts.push(environment.to_string());
    // Build definitions and configuration, by content.
    let defs: Vec<(&String, String)> = tree.iter().filter(|(p, _)| affects_graph(p)).map(|(p, e)| (p, format!("{} {}", mode_name(e.mode), e.oid))).collect();
    parts.push(format!("definitions {}", defs.len()));
    for (p, v) in defs {
        parts.push(p.clone());
        parts.push(v);
    }
    // Which files exist, for glob().
    let files: Vec<(&String, &'static str)> = tree.iter().filter(|(p, _)| workspace.is_empty() || is_under(p, workspace)).map(|(p, e)| (p, mode_name(e.mode))).collect();
    parts.push(format!("paths {}", files.len()));
    for (p, m) in files {
        parts.push(format!("{m} {p}"));
    }
    crate::store::digest(parts)
}

/// What a graph depends on outside the tree, for the workspace at `dir` (in an app-owned tree): the Bazel
/// version that runs there, the Xcode that `tools/bazel` and Bazel's toolchain detection see, the
/// environment Bazel and Bazelisk read, the PATH tools get, and the bazelrc files outside the tree.
/// `xcode` is `xcode()`, read once per review. Fails when Bazel can't say its version; the graph is then
/// queried and not cached.
pub fn environment(bazel: &Path, dir: &Path, tree: &Tree, workspace: &str, xcode: &str, cancel: &Cancel) -> Result<String> {
    let mut parts: Vec<String> = Vec::new();
    parts.push(format!("bazel {}", bazel_version(bazel, dir, tree, workspace, cancel)?));
    parts.push(format!("xcode {xcode}"));
    parts.push(format!("PATH {}", crate::tools::child_path().to_string_lossy()));
    let mut vars: Vec<(String, String)> = std::env::vars()
        .filter(|(k, _)| {
            k.starts_with("BAZEL")
                || k.starts_with("USE_BAZEL")
                || ["DEVELOPER_DIR", "XCODE_VERSION", "JAVA_HOME", "HOME", "CC", "CXX", "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_NDK_HOME", "SDKROOT"].contains(&k.as_str())
        })
        .collect();
    vars.sort();
    for (k, v) in vars {
        parts.push(format!("{k}={v}"));
    }
    // Bazel reads these unless told not to, and the app doesn't tell it.
    let mut rc: Vec<PathBuf> = vec![PathBuf::from("/etc/bazel.bazelrc")];
    if let Some(home) = std::env::var_os("HOME") {
        rc.push(PathBuf::from(home).join(".bazelrc"));
    }
    // Files outside the tree that the workspace's .bazelrc imports, at any depth.
    rc.extend(rc_imports(dir));
    for path in rc {
        let content = std::fs::read(&path).map(|b| crate::store::digest([b])).unwrap_or_else(|_| "missing".to_string());
        parts.push(format!("rc {} {content}", path.display()));
    }
    Ok(crate::store::digest(parts))
}

/// Absolute paths that `import` and `try-import` lines name, starting from `<dir>/.bazelrc` and following
/// imports inside the workspace (`%workspace%/…`, which the tree's own entries already cover).
fn rc_imports(dir: &Path) -> Vec<PathBuf> {
    let mut outside: Vec<PathBuf> = Vec::new();
    let mut seen: Vec<PathBuf> = Vec::new();
    let mut queue: Vec<PathBuf> = vec![dir.join(".bazelrc")];
    while let Some(file) = queue.pop() {
        if seen.contains(&file) || seen.len() > 64 {
            continue;
        }
        seen.push(file.clone());
        let Ok(text) = std::fs::read_to_string(&file) else { continue };
        for line in text.lines() {
            let line = line.trim();
            let Some(rest) = line.strip_prefix("try-import").or_else(|| line.strip_prefix("import")) else { continue };
            let target = rest.trim().trim_matches('"');
            if target.is_empty() {
                continue;
            }
            if let Some(inside) = target.strip_prefix("%workspace%/") {
                queue.push(dir.join(inside));
            } else {
                let path = PathBuf::from(target);
                if path.is_absolute() {
                    outside.push(path.clone());
                    queue.push(path);
                }
            }
        }
    }
    outside
}

/// `bazel --version` in the workspace, where Bazelisk picks the version from `.bazelversion`. Kept per
/// process for the same Bazel binary and the same files that choose the version.
fn bazel_version(bazel: &Path, dir: &Path, tree: &Tree, workspace: &str, cancel: &Cancel) -> Result<String> {
    static VERSIONS: Mutex<BTreeMap<String, String>> = Mutex::new(BTreeMap::new());
    let binary = std::fs::canonicalize(bazel).unwrap_or_else(|_| bazel.to_path_buf());
    let stamp = std::fs::metadata(&binary).and_then(|m| m.modified()).map(|t| format!("{t:?}")).unwrap_or_default();
    let mut memo = format!("{} {stamp}", binary.display());
    for name in [".bazelversion", ".bazeliskrc", "tools/bazel"] {
        let entry = tree.get(&crate::paths::join(workspace, name)).map(|e| e.oid.to_string()).unwrap_or_default();
        memo.push_str(&format!(" {name}={entry}"));
    }
    if let Some(v) = VERSIONS.lock().unwrap().get(&memo) {
        return Ok(v.clone());
    }
    let out = Cmd::new(bazel).arg("--version").cwd(dir).what("graph key").output_string(cancel)?;
    if out.is_empty() {
        return Err(anyhow!("bazel --version printed nothing"));
    }
    let version = format!("{out} ({memo})");
    VERSIONS.lock().unwrap().insert(memo, version.clone());
    Ok(version)
}

/// The selected Xcode, as `tools/bazel` sets XCODE_VERSION: the caller's value, or the developer
/// directory and a digest of its version.plist. Read for every review, not once per process: the app runs
/// many reviews in one process, and Xcode can be updated in place meanwhile.
pub fn xcode() -> String {
    let set = std::env::var("XCODE_VERSION").unwrap_or_default();
    let developer_dir = match std::env::var("DEVELOPER_DIR") {
        Ok(d) if !d.is_empty() => d,
        _ => std::process::Command::new("/usr/bin/xcode-select")
            .arg("-p")
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default(),
    };
    let plist = if developer_dir.is_empty() {
        "none".to_string()
    } else {
        std::fs::read(Path::new(&developer_dir).join("../version.plist")).map(|b| crate::store::digest([b])).unwrap_or_else(|_| "missing".to_string())
    };
    format!("set={set:?} dir={developer_dir:?} plist={plist}")
}

/// The graph cache of one repository.
pub struct GraphCache {
    dir: PathBuf,
}

impl GraphCache {
    pub fn new(repo_root: &Path) -> GraphCache {
        GraphCache { dir: crate::store::cache_root().join("graphs").join(crate::store::repo_key(repo_root)) }
    }

    pub fn get(&self, key: &str) -> Option<WorkspaceGraph> {
        let data = std::fs::read(self.dir.join(format!("{key}.json"))).ok()?;
        serde_json::from_slice(&data).ok()
    }

    /// Keeps a complete graph. Returns false for a graph that names a path of the app-owned trees
    /// (`private`), which is not kept: it would not be the same at the other side, or in another home.
    /// Failing to write is no error; the graph is queried again next time.
    pub fn put(&self, key: &str, graph: &WorkspaceGraph, private: &[&Path]) -> bool {
        let Ok(data) = serde_json::to_vec(graph) else { return false };
        let text = String::from_utf8_lossy(&data);
        if private.iter().any(|p| text.contains(p.to_string_lossy().as_ref())) {
            return false;
        }
        if std::fs::create_dir_all(&self.dir).is_ok() {
            let path = self.dir.join(format!("{key}.json"));
            let tmp = self.dir.join(format!("{key}.json.{}.tmp", std::process::id()));
            if std::fs::write(&tmp, &data).is_err() || std::fs::rename(&tmp, &path).is_err() {
                let _ = std::fs::remove_file(&tmp);
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::git::TreeEntry;
    use gix::ObjectId;

    fn entry(n: u8) -> TreeEntry {
        TreeEntry { oid: ObjectId::from_bytes_or_panic(&[n; 20]), mode: EntryMode::File }
    }

    fn tree() -> Tree {
        let mut t = Tree::new();
        t.insert("MODULE.bazel".into(), entry(1));
        t.insert(".bazelrc".into(), entry(2));
        t.insert("app/BUILD.bazel".into(), entry(3));
        t.insert("app/Sources/App.swift".into(), entry(4));
        t.insert("app/Sources/View.swift".into(), entry(5));
        t.insert("README.md".into(), entry(6));
        t
    }

    fn scope() -> Scope {
        Scope { targets: vec!["//app:App".into()], kind: "explicit".into() }
    }

    fn key(t: &Tree, scope: &Scope, args: &[String]) -> String {
        graph_key(t, "", scope, args, "env")
    }

    #[test]
    fn the_key_changes_with_every_input_of_the_graph() {
        let base = key(&tree(), &scope(), &[]);
        assert_eq!(base, key(&tree(), &scope(), &[]));

        let mut changed_build = tree();
        changed_build.insert("app/BUILD.bazel".into(), entry(30));
        assert_ne!(base, key(&changed_build, &scope(), &[]), "a changed BUILD.bazel");

        let mut added = tree();
        added.insert("app/Sources/New.swift".into(), entry(7));
        assert_ne!(base, key(&added, &scope(), &[]), "a file added in a package");

        let mut removed = tree();
        removed.remove("app/Sources/View.swift");
        assert_ne!(base, key(&removed, &scope(), &[]), "a file removed from a package");

        assert_ne!(base, key(&tree(), &scope(), &["--config=release".into()]), "a Bazel argument");
        assert_ne!(base, key(&tree(), &Scope { targets: vec!["//app:Tests".into()], kind: "explicit".into() }, &[]), "other scope targets");
        assert_ne!(base, key(&tree(), &Scope { targets: vec!["//...".into()], kind: "all".into() }, &[]), "another scope kind");
        assert_ne!(base, graph_key(&tree(), "", &scope(), &[], "other env"), "another environment");
        assert_ne!(base, graph_key(&tree(), "app", &scope(), &[], "env"), "another workspace");

        let mut rc = tree();
        rc.insert(".bazelrc".into(), entry(20));
        assert_ne!(base, key(&rc, &scope(), &[]), "a changed .bazelrc");

        let mut swift = tree();
        swift.insert("app/Sources/App.swift".into(), entry(40));
        assert_eq!(base, key(&swift, &scope(), &[]), "an unrelated .swift content change");

        let mut readme = tree();
        readme.insert("README.md".into(), entry(60));
        assert_eq!(base, key(&readme, &scope(), &[]), "an unrelated README change");
    }

    #[test]
    fn a_nested_workspace_lists_only_its_own_paths_but_every_build_definition() {
        let mut t = tree();
        t.insert("nested/MODULE.bazel".into(), entry(8));
        t.insert("nested/lib/Lib.swift".into(), entry(9));
        let nested = graph_key(&t, "nested", &scope(), &[], "env");
        let mut added_outside = t.clone();
        added_outside.insert("app/Sources/Other.swift".into(), entry(10));
        assert_eq!(nested, graph_key(&added_outside, "nested", &scope(), &[], "env"), "a file added outside the workspace");
        let mut build_outside = t.clone();
        build_outside.insert("app/BUILD.bazel".into(), entry(11));
        assert_ne!(nested, graph_key(&build_outside, "nested", &scope(), &[], "env"), "a build file changed outside the workspace");
    }

    #[test]
    fn graph_affecting_files() {
        for p in [
            "BUILD",
            "a/BUILD.bazel",
            "third_party/BUILD.zlib.bazel",
            "MODULE.bazel",
            "MODULE.bazel.lock",
            "deps.MODULE.bazel",
            "REPO.bazel",
            "tools/defs.bzl",
            ".bazelrc",
            "ci.bazelrc",
            "Cargo.lock",
            "app/package.json",
            "pnpm-lock.yaml",
            "Package.resolved",
            "maven_install.json",
            "tools/bazel",
            "patches/fix.patch",
        ] {
            assert!(affects_graph(p), "{p}");
        }
        for p in ["app/Sources/App.swift", "README.md", "app/src/main.ts", "tsconfig.json", "tools/bazel.md"] {
            assert!(!affects_graph(p), "{p}");
        }
    }

    #[test]
    fn rc_imports_outside_the_workspace_are_followed() {
        let dir = std::env::temp_dir().join(format!("reviewmap-rc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let outside = dir.join("outside.bazelrc");
        std::fs::write(&outside, "build --config=x\n").unwrap();
        std::fs::write(dir.join("user.bazelrc"), format!("try-import {}\n", outside.display())).unwrap();
        std::fs::write(dir.join(".bazelrc"), "import %workspace%/user.bazelrc\ntry-import %workspace%/missing.bazelrc\n").unwrap();
        assert_eq!(rc_imports(&dir), vec![outside]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
