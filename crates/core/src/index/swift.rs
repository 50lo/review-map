//! Swift's index: the compiler's index store, built by Bazel in an app-owned workspace and read by the
//! Swift helper (IndexStoreDB).
//!
//! The build asks only for index stores. An aspect, written into the app-owned tree, follows the
//! dependencies of the selected targets and collects each Swift target's declared `.indexstore`
//! directory, so Bazel compiles what the indexes need and skips linking, bundling, signing, and tests,
//! while libraries are still reached through the application's platform configuration. The declared
//! artifacts are named in the build's event file, so stores that came from an action or remote cache are
//! collected too, and nothing stale from an earlier revision in the same output base is read. When the
//! aspect finds nothing (rules that don't expose the output group), the prototype's build of the targets
//! themselves with `--output_groups=+swift_index_store` stands in.
//!
//! The result is kept per repository, workspace, commit, targets, configuration, and toolchain. An index
//! for head never describes base.

use super::IndexedRef;
use crate::bazel::workspace::BazelEnv;
use crate::model::Side;
use crate::parse::swift_helper::{IndexRequest, IndexRoot, SwiftHelper};
use crate::proc::{log_tail, Cancel, Log};
use anyhow::{anyhow, bail, Context, Result};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

pub const ASPECT_PACKAGE: &str = ".reviewmap_aspects";
const OUTPUT_GROUP: &str = "reviewmap_swift_index";
const FORMAT: &str = "swift-index-2";

pub struct SwiftIndexJob<'a> {
    pub env: &'a BazelEnv,
    pub side: Side,
    pub sha: &'a str,
    /// Repo-relative workspace directory ("" for the root).
    pub workspace: &'a str,
    pub targets: &'a [String],
    /// The app-owned tree of the side (the repository root at this revision).
    pub tree_dir: &'a Path,
    /// Repo-relative Swift files of the side that belong to this workspace.
    pub files: Vec<String>,
    /// Where this repository's Swift indexes are kept.
    pub cache_dir: PathBuf,
}

pub struct SwiftIndexResult {
    pub refs: BTreeMap<String, Vec<IndexedRef>>,
    /// Set when the build had errors and the index covers only what compiled.
    pub partial: Option<String>,
}

/// The aspect that collects declared index stores along dependency edges.
pub fn aspect() -> &'static str {
    r#""""Written by Review Map: the index stores of the Swift targets that the selected targets depend on."""

_Stores = provider(fields = ["files"])

def _impl(target, ctx):
    transitive = []
    for name in dir(ctx.rule.attr):
        value = getattr(ctx.rule.attr, name, None)
        deps = value if type(value) == "list" else [value]
        for dep in deps:
            if type(dep) == "Target" and _Stores in dep:
                transitive.append(dep[_Stores].files)
    if OutputGroupInfo in target and hasattr(target[OutputGroupInfo], "swift_index_store"):
        transitive.append(target[OutputGroupInfo].swift_index_store)
    files = depset(transitive = transitive)
    return [_Stores(files = files), OutputGroupInfo(reviewmap_swift_index = files)]

reviewmap_swift_index = aspect(
    implementation = _impl,
    attr_aspects = ["*"],
)
"#
}

/// Writes the app's aspects into a workspace of the app-owned tree. They are not part of the reviewed
/// revision, so the tree update leaves them alone.
pub fn write_aspects(workspace_dir: &Path, kotlin_aspect: Option<&str>) -> Result<()> {
    let dir = workspace_dir.join(ASPECT_PACKAGE);
    std::fs::create_dir_all(&dir)?;
    let write = |name: &str, text: &str| -> Result<()> {
        let path = dir.join(name);
        // Unchanged files keep their timestamps, so Bazel doesn't reload the package.
        if std::fs::read_to_string(&path).ok().as_deref() != Some(text) {
            std::fs::write(&path, text)?;
        }
        Ok(())
    };
    write("BUILD.bazel", "")?;
    write("swift_index.bzl", aspect())?;
    if let Some(text) = kotlin_aspect {
        write("kotlin_index.bzl", text)?;
    }
    Ok(())
}

/// Paths of the files a build's event file names, for the output groups that were requested.
pub fn bep_files(path: &Path) -> Vec<String> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    let mut out = Vec::new();
    for line in text.lines() {
        if !line.contains("\"namedSetOfFiles\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        for f in v.get("namedSetOfFiles").and_then(|n| n.get("files")).and_then(|f| f.as_array()).into_iter().flatten() {
            if let Some(uri) = f.get("uri").and_then(|u| u.as_str()) {
                if let Some(p) = uri.strip_prefix("file://") {
                    out.push(percent_decode(p));
                }
            }
        }
    }
    out
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The `.indexstore` directories among a build's output files.
fn index_stores(files: &[String]) -> BTreeSet<PathBuf> {
    let mut stores = BTreeSet::new();
    for f in files {
        if let Some(i) = f.find(".indexstore") {
            let end = i + ".indexstore".len();
            if f.len() == end || f.as_bytes()[end] == b'/' {
                stores.insert(PathBuf::from(&f[..end]));
            }
        }
    }
    stores
}

/// Copies the units and records of a store into `dest`. File names are content hashes, so stores merge by copying.
fn merge_store(store: &Path, dest: &Path) -> Result<usize> {
    let mut copied = 0;
    for version in ["v5", "v6"] {
        let src = store.join(version);
        if !src.is_dir() {
            continue;
        }
        let mut stack = vec![src.clone()];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir)?.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                    continue;
                }
                let Ok(rel) = path.strip_prefix(store) else { continue };
                let target = dest.join(rel);
                if target.exists() {
                    continue;
                }
                if let Some(parent) = target.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                if std::fs::copy(&path, &target).is_ok() {
                    copied += 1;
                }
            }
        }
    }
    Ok(copied)
}

/// What identifies the toolchain that builds and reads the store.
fn toolchain_id(library: &Path) -> String {
    let stamp = std::fs::metadata(library).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    format!("{}@{stamp}", library.display())
}

/// Loads the index of one workspace at one side, building it when it isn't cached.
pub fn load(job: &SwiftIndexJob, helper: &mut SwiftHelper, cancel: &Cancel, log: Log) -> Result<SwiftIndexResult> {
    let library = crate::tools::lib_index_store()
        .ok_or_else(|| anyhow!("Can't find libIndexStore next to the Swift toolchain. Set REVIEWMAP_LIBINDEXSTORE to its path."))?;
    let key = crate::store::digest([
        FORMAT.as_bytes(),
        job.workspace.as_bytes(),
        job.sha.as_bytes(),
        job.targets.join("\n").as_bytes(),
        job.env.args.join("\n").as_bytes(),
        toolchain_id(&library).as_bytes(),
        helper.version.as_bytes(),
    ]);
    let cache = job.cache_dir.join(&key[..24]);
    let refs_path = cache.join("refs.json");
    let at = if job.workspace.is_empty() { String::new() } else { format!(" in {}", job.workspace) };
    if let Ok(data) = std::fs::read(&refs_path) {
        if let Ok(refs) = serde_json::from_slice::<BTreeMap<String, Vec<IndexedRef>>>(&data) {
            log(format!("Swift index for {} {}{at}: cached", job.side.name(), &job.sha[..job.sha.len().min(8)]));
            return Ok(SwiftIndexResult { refs, partial: None });
        }
    }
    std::fs::create_dir_all(&cache)?;
    let log_path = cache.join("build.log");
    let _ = std::fs::remove_file(&log_path);
    write_aspects(&job.env.dir, None)?;

    let bep = cache.join("build-events.json");
    let build = |aspect: bool| -> Result<(bool, BTreeSet<PathBuf>)> {
        let _ = std::fs::remove_file(&bep);
        let mut cmd = job
            .env
            .command("build")
            .what("swift index")
            .arg("--features=swift.index_while_building")
            .arg("--features=swift.use_global_index_store")
            .arg("--remote_download_regex=.*[.]indexstore(/.*)?")
            .arg(format!("--disk_cache={}", crate::bazel::workspace::Workspaces::disk_cache().display()))
            .arg(format!("--build_event_json_file={}", bep.display()))
            .arg("--experimental_convenience_symlinks=ignore")
            .arg("--keep_going");
        cmd = if aspect {
            cmd.arg(format!("--aspects=//{ASPECT_PACKAGE}:swift_index.bzl%{OUTPUT_GROUP}")).arg(format!("--output_groups={OUTPUT_GROUP}"))
        } else {
            cmd.arg("--output_groups=+swift_index_store")
        };
        let status = cmd.args(job.env.args.iter().cloned()).arg("--").args(job.targets.iter().cloned()).run_logged(&log_path, cancel)?;
        Ok((status.success(), index_stores(&bep_files(&bep))))
    };
    log(format!(
        "Building the Swift index of {} {}{at} ({}); this runs once per commit",
        job.side.name(),
        &job.sha[..job.sha.len().min(8)],
        job.targets.join(" ")
    ));
    let start = std::time::Instant::now();
    let (mut ok, mut stores) = build(true)?;
    if stores.is_empty() {
        // Rules that don't expose the output group to an aspect: build the targets themselves, as the prototype did.
        log(format!("No index stores through the aspect{at}; building the targets with index stores as extra outputs"));
        let (ok2, stores2) = build(false)?;
        ok = ok2;
        stores = stores2;
        if stores.is_empty() {
            // Older rules write the store only as a side effect of compiling.
            let info = job.env.info(&["output_path"], cancel).unwrap_or_default();
            if let Some(global) = info.get("output_path").map(|p| Path::new(p).join("_global_index_store")).filter(|p| p.join("v5").is_dir()) {
                stores.insert(global);
            }
        }
    }
    if stores.is_empty() {
        bail!(
            "The {} build produced no Swift index store{at}{}. Log: {}\n{}",
            job.side.name(),
            if ok { "" } else { " (it failed)" },
            log_path.display(),
            log_tail(&log_path, 6)
        );
    }
    let store_dir = cache.join("store");
    let _ = std::fs::remove_dir_all(&store_dir);
    let _ = std::fs::remove_dir_all(cache.join("db"));
    let merging = crate::proc::timer(format!("swift merge stores ({}, {} stores)", job.side.name(), stores.len()));
    for store in &stores {
        merge_store(store, &store_dir).with_context(|| format!("could not copy {}", store.display()))?;
    }
    drop(merging);
    let execution_root = job.env.info(&["execution_root"], cancel)?.remove("execution_root").unwrap_or_default();
    let mut roots = vec![IndexRoot { path: job.tree_dir.to_string_lossy().to_string(), prefix: String::new() }];
    if !execution_root.is_empty() {
        // The execution root mirrors the Bazel workspace, which may be a subdirectory of the repo.
        roots.push(IndexRoot { path: execution_root.clone(), prefix: job.workspace.to_string() });
    }
    log(format!("Reading the Swift index of {}{at} ({} stores)", job.side.name(), stores.len()));
    let request = IndexRequest {
        store_path: store_dir.to_string_lossy().to_string(),
        database_path: cache.join("db").to_string_lossy().to_string(),
        library_path: library.to_string_lossy().to_string(),
        roots,
        prefix_map_root: (!execution_root.is_empty()).then_some(execution_root),
        files: job.files.clone(),
    };
    let reading = crate::proc::timer(format!("swift helper read ({})", job.side.name()));
    let refs = helper.index(&request, cancel)?;
    drop(reading);
    log(format!("Indexed {} of {} Swift files at {}{at} in {}s", refs.len(), job.files.len(), job.side.name(), start.elapsed().as_secs()));
    let partial = (!ok).then(|| format!("The Swift index build of {}{at} had errors, so the index covers only what compiled. Log: {}", job.side.name(), log_path.display()));
    if ok {
        // Only a complete index is kept: a partial one would hide the next attempt's chance to do better.
        if let Ok(data) = serde_json::to_vec(&refs) {
            let _ = std::fs::write(&refs_path, data);
        }
        // The store and its database are derived data; the references are what later runs read.
        let _ = std::fs::remove_dir_all(&store_dir);
        let _ = std::fs::remove_dir_all(cache.join("db"));
    }
    Ok(SwiftIndexResult { refs, partial })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_stores_in_build_events() {
        let files = vec![
            "/out/bazel-out/ios-fastbuild/bin/app/AppLib.indexstore/v5/units/a".to_string(),
            "/out/bazel-out/ios-fastbuild/bin/app/AppLib.indexstore/v5/records/AB/b".to_string(),
            "/out/bazel-out/ios-fastbuild/bin/core/Core.indexstore".to_string(),
            "/out/bazel-out/ios-fastbuild/bin/core/Core.swiftmodule".to_string(),
        ];
        let stores: Vec<String> = index_stores(&files).into_iter().map(|p| p.to_string_lossy().to_string()).collect();
        assert_eq!(stores, vec!["/out/bazel-out/ios-fastbuild/bin/app/AppLib.indexstore", "/out/bazel-out/ios-fastbuild/bin/core/Core.indexstore"]);
        assert_eq!(percent_decode("/a%20b/c"), "/a b/c");
    }
}
