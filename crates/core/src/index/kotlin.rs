//! Kotlin's index for Bazel workspaces that build Kotlin with rules_kotlin.
//!
//! scip-java's own Bazel aspect covers javac only, so the app drives the Kotlin indexer itself, as the
//! prototype did:
//!
//! 1. An aspect, written into the app-owned tree, lists each rules_kotlin target's Kotlin sources and its
//!    compile classpath in order, with the target that produced each jar. Building its output group
//!    builds the classpath jars too.
//! 2. The Kotlin indexer in the scip-java launcher indexes each target's sources against its classpath.
//!
//! What changed from the prototype is identity. Symbols of a Bazel build carry no coordinates
//! ("scip-java maven . . demo/start()."), so the same symbol can be declared by several targets, and one
//! merged index can't tell them apart. Here every configured target keeps its own index, and a
//! reference is resolved the way the compiler resolved it: to a declaration in the referring target's
//! own sources, or else in the first classpath jar, in classpath order, whose owning target declares the
//! symbol. Nothing is inferred from a matching name: a symbol that no source or classpath owner of the
//! referring target declares stays unresolved. A file that several targets compile is indexed in each,
//! and its references are the union of what each target resolved.
//!
//! Indexes are cached per configured target, by its sources' contents, its classpath jars' contents, and
//! the indexer version, so they are reused across revisions, sides, and checkouts.

use super::scip;
use super::swift::{bep_files, write_aspects, ASPECT_PACKAGE};
use super::{IndexedRef, SideIndex};
use crate::bazel::workspace::{BazelEnv, Workspaces};
use crate::model::{Side, Warning};
use crate::paths::join;
use crate::proc::{log_tail, Cancel, Cmd, Log};
use anyhow::{anyhow, bail, Context, Result};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// The scip-java release whose launcher is downloaded when `REVIEWMAP_SCIP_JAVA` doesn't name one.
pub const SCIP_JAVA_VERSION: &str = "v0.14.1";
const INDEXER_MAIN_CLASS: &str = "org.scip_code.scip_java.kotlin_analysis.MainKt";
const OUTPUT_GROUP: &str = "reviewmap_kotlin";
const MANIFEST_SUFFIX: &str = ".reviewmap_kotlin.json";
const FORMAT: &str = "kotlin-target-index-1";

/// A jar on a target's compile classpath, and the workspace target that produced it ("" for a jar from
/// outside the workspace).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct ClasspathEntry {
    pub path: String,
    #[serde(default)]
    pub owner: String,
}

/// A rules_kotlin target as the aspect lists it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct KotlinTarget {
    /// Such as "//app:app".
    pub label: String,
    /// Kotlin sources, relative to the Bazel workspace.
    pub sources: Vec<String>,
    /// The compile classpath in the compiler's order; paths are relative to the execution root.
    pub classpath: Vec<ClasspathEntry>,
    /// The configuration the manifest was written in (its directory under bazel-out), from the build's event file.
    #[serde(default)]
    pub config: String,
}

/// The aspect. It follows dependency edges and passes the manifests up, so a target set like `//app:app`
/// also indexes the libraries it uses. Only the workspace's own sources are listed, and a target's own
/// jars stay off its classpath.
pub fn aspect(rules_kotlin_repo: &str) -> String {
    format!(
        r#""""Written by Review Map: the Kotlin sources and compile classpath of each rules_kotlin target."""

load("@{rules_kotlin_repo}//kotlin/internal:defs.bzl", "KtJvmInfo")

_ATTRS = ["deps", "exports", "associates", "runtime_deps"]

_Manifests = provider(fields = ["files"])

def _main_repo(f):
    return not f.short_path.startswith("../")

def _owner(jar):
    if not jar.owner or not _main_repo(jar):
        return ""
    return "//" + jar.owner.package + ":" + jar.owner.name

def _impl(target, ctx):
    # The dependencies' manifests and jars, so that building the top-level targets builds them all.
    transitive = []
    for attr in _ATTRS:
        for dep in getattr(ctx.rule.attr, attr, []) or []:
            if type(dep) == "Target" and _Manifests in dep:
                transitive.append(dep[_Manifests].files)
    srcs = []
    if KtJvmInfo in target:
        srcs = [f for f in target[KtJvmInfo].srcs if f.extension == "kt" and f.is_source and _main_repo(f)]
    if srcs:
        jars = target[KtJvmInfo].transitive_compile_time_jars
        classpath = [j for j in jars.to_list() if j.owner != target.label]
        manifest = ctx.actions.declare_file(target.label.name + "{MANIFEST_SUFFIX}")
        ctx.actions.write(manifest, json.encode({{
            "label": "//" + target.label.package + ":" + target.label.name,
            "sources": [f.path for f in srcs],
            "classpath": [{{"path": j.path, "owner": _owner(j)}} for j in classpath],
        }}))
        transitive.append(depset([manifest], transitive = [jars]))
    files = depset(transitive = transitive)
    return [_Manifests(files = files), OutputGroupInfo({OUTPUT_GROUP} = files)]

reviewmap_kotlin = aspect(
    implementation = _impl,
    attr_aspects = _ATTRS,
)
"#
    )
}

pub struct KotlinIndexJob<'a> {
    pub env: &'a BazelEnv,
    pub side: Side,
    pub sha: &'a str,
    /// Repo-relative workspace directory ("" for the root).
    pub workspace: &'a str,
    pub targets: &'a [String],
    /// Blob ids of the side's Kotlin files by repo-relative path, for cache keys.
    pub blobs: &'a BTreeMap<String, String>,
    /// Where index logs go.
    pub log_dir: PathBuf,
}

/// One configured target's index: its documents, with paths relative to the workspace.
pub struct TargetIndex {
    pub target: KotlinTarget,
    pub index: scip::Index,
}

/// Loads the Kotlin index of one workspace at one side.
pub fn load(job: &KotlinIndexJob, cancel: &Cancel, log: Log) -> Result<SideIndex> {
    let at = if job.workspace.is_empty() { String::new() } else { format!(" in {}", job.workspace) };
    let java = crate::tools::java().ok_or_else(|| anyhow!("Kotlin indexing needs a JDK 17 or newer (java on the PATH, or JAVA_HOME)."))?;
    let launcher = scip_java_launcher(cancel, log)?;
    std::fs::create_dir_all(&job.log_dir)?;
    let log_path = job.log_dir.join(format!("kotlin-{}-{}.log", job.side.name(), &job.sha[..job.sha.len().min(12)]));
    let _ = std::fs::remove_file(&log_path);

    let module = std::fs::read_to_string(job.env.dir.join("MODULE.bazel")).unwrap_or_default();
    write_aspects(&job.env.dir, Some(&aspect(&crate::bazel::module_repo_name(&module, "rules_kotlin"))))?;
    let bep = job.log_dir.join(format!("kotlin-{}-events.json", job.side.name()));
    let _ = std::fs::remove_file(&bep);
    log(format!("Building {} {}{at} with Bazel for the Kotlin index", job.side.name(), &job.sha[..job.sha.len().min(8)]));
    let start = std::time::Instant::now();
    let status = job
        .env
        .command("build")
        .arg(format!("--aspects=//{ASPECT_PACKAGE}:kotlin_index.bzl%reviewmap_kotlin"))
        .arg(format!("--output_groups={OUTPUT_GROUP}"))
        .arg(format!("--disk_cache={}", Workspaces::disk_cache().display()))
        .arg(format!("--build_event_json_file={}", bep.display()))
        .arg("--experimental_convenience_symlinks=ignore")
        .arg("--keep_going")
        .args(job.env.args.iter().cloned())
        .arg("--")
        .args(job.targets.iter().cloned())
        .run_logged(&log_path, cancel)?;
    let build_ok = status.success();
    let execution_root = job.env.info(&["execution_root"], cancel)?.remove("execution_root").unwrap_or_default();
    if execution_root.is_empty() {
        bail!("bazel info gave no execution root at {}{at}. Log: {}", job.side.name(), log_path.display());
    }
    let targets = read_manifests(&bep_files(&bep));
    if targets.is_empty() {
        bail!(
            "{} in {}{at} at {}. Log: {}\n{}",
            if build_ok { "No rules_kotlin targets with Kotlin sources" } else { "The Bazel build for the Kotlin index failed" },
            job.targets.join(" "),
            job.side.name(),
            log_path.display(),
            log_tail(&log_path, 6)
        );
    }

    // Each configured target is indexed on its own, a few at a time, and cached by its inputs.
    let cache_dir = crate::store::cache_root().join("index").join("kotlin").join("targets");
    let jar_digests: Mutex<HashMap<String, String>> = Mutex::new(HashMap::new());
    let java_id = Cmd::new(&java).arg("-version").output_string(cancel).ok().unwrap_or_default();
    let exec_root = Path::new(&execution_root);
    let done = std::sync::atomic::AtomicUsize::new(0);
    let total = targets.len();
    let pool = rayon::ThreadPoolBuilder::new().num_threads(index_jobs()).build().context("could not start the Kotlin index workers")?;
    let results: Vec<(KotlinTarget, Result<scip::Index>)> = pool.install(|| {
        targets
            .par_iter()
            .map(|t| {
                let result = index_target(job, t, exec_root, &java, &launcher, &java_id, &cache_dir, &jar_digests, &log_path, cancel);
                let n = done.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                log(format!("Kotlin index of {}{at}: {n} of {total} targets ({})", job.side.name(), t.label));
                (t.clone(), result)
            })
            .collect()
    });
    cancel.check()?;
    let mut indexed: Vec<TargetIndex> = Vec::new();
    let mut failed: Vec<String> = Vec::new();
    for (target, result) in results {
        match result {
            Ok(index) => indexed.push(TargetIndex { target, index }),
            Err(e) => {
                if crate::proc::is_cancelled(&e) {
                    return Err(e);
                }
                failed.push(target.label);
            }
        }
    }
    if indexed.is_empty() {
        bail!("The Kotlin indexer failed for every target at {}{at}. Log: {}\n{}", job.side.name(), log_path.display(), log_tail(&log_path, 6));
    }
    let mut side = resolve(&indexed, job.workspace);
    if !failed.is_empty() || !build_ok {
        let what = if failed.is_empty() {
            "the Bazel build had errors".to_string()
        } else {
            format!("the indexer failed for {} target{} (first: {})", failed.len(), if failed.len() == 1 { "" } else { "s" }, failed[..failed.len().min(3)].join(", "))
        };
        side.warnings.push(Warning::new(
            "index-partial",
            format!("The Kotlin index of {}{at} is incomplete: {what}. Files without index data show only links that syntax proves. Log: {}", job.side.name(), log_path.display()),
        ));
    }
    log(format!("Indexed {} Kotlin targets at {}{at} in {}s", indexed.len(), job.side.name(), start.elapsed().as_secs()));
    Ok(side)
}

/// How many targets are indexed at once: each is a JVM with the Kotlin Analysis API loaded.
fn index_jobs() -> usize {
    if let Some(n) = std::env::var("REVIEWMAP_KOTLIN_JOBS").ok().and_then(|v| v.parse::<usize>().ok()) {
        return n.max(1);
    }
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    (cores / 3).clamp(1, 4)
}

/// The manifests a build named in its event file, each with the configuration directory it was written in.
fn read_manifests(files: &[String]) -> Vec<KotlinTarget> {
    let mut out: BTreeMap<(String, String), KotlinTarget> = BTreeMap::new();
    for f in files.iter().filter(|f| f.ends_with(MANIFEST_SUFFIX)) {
        let Ok(data) = std::fs::read(f) else { continue };
        let Ok(mut target) = serde_json::from_slice::<KotlinTarget>(&data) else { continue };
        // ".../bazel-out/darwin_arm64-fastbuild/bin/app/app.reviewmap_kotlin.json" -> "darwin_arm64-fastbuild"
        target.config = f.split("/bazel-out/").nth(1).and_then(|rest| rest.split('/').next()).unwrap_or("").to_string();
        out.insert((target.label.clone(), target.config.clone()), target);
    }
    out.into_values().collect()
}

fn file_digest(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path).with_context(|| format!("could not read {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 16];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(crate::store::hex(&hasher.finalize()))
}

/// The index of one configured target: from the cache when its inputs are the same, else from the indexer.
#[allow(clippy::too_many_arguments)]
fn index_target(
    job: &KotlinIndexJob,
    target: &KotlinTarget,
    exec_root: &Path,
    java: &Path,
    launcher: &Path,
    java_id: &str,
    cache_dir: &Path,
    jar_digests: &Mutex<HashMap<String, String>>,
    log_path: &Path,
    cancel: &Cancel,
) -> Result<scip::Index> {
    cancel.check()?;
    // The key: what the indexer reads. Sources by content, jars by content, and the tools' versions. No
    // absolute path is in it, so the index serves any checkout and both sides.
    let mut parts: Vec<String> = vec![FORMAT.to_string(), SCIP_JAVA_VERSION.to_string(), java_id.to_string(), target.label.clone(), target.config.clone()];
    for s in &target.sources {
        let repo_path = join(job.workspace, s);
        let id = match job.blobs.get(&repo_path) {
            Some(id) => id.clone(),
            None => file_digest(&job.env.dir.join(s))?,
        };
        parts.push(format!("src {s} {id}"));
    }
    for entry in &target.classpath {
        let known = jar_digests.lock().unwrap().get(&entry.path).cloned();
        let digest = match known {
            Some(d) => d,
            None => {
                let d = file_digest(&exec_root.join(&entry.path))?;
                jar_digests.lock().unwrap().insert(entry.path.clone(), d.clone());
                d
            }
        };
        // The jar's name is not part of the key: the same classes under another path are the same input.
        parts.push(format!("jar {digest}"));
    }
    let key = crate::store::digest(parts.iter().map(String::as_bytes));
    let cached = cache_dir.join(&key[..2]).join(format!("{}.scip", &key[2..]));
    if let Ok(data) = std::fs::read(&cached) {
        if let Ok(index) = scip::decode(&data) {
            return Ok(index);
        }
    }
    let scratch = cache_dir.join(format!("tmp-{}-{}", std::process::id(), &key[..16]));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch)?;
    let result = (|| -> Result<scip::Index> {
        let target_root = scratch.join("targetroot");
        let classpath: Vec<String> = target.classpath.iter().map(|e| exec_root.join(&e.path).to_string_lossy().to_string()).collect();
        let mut cmd = Cmd::new(java)
            .arg("-cp")
            .arg(launcher.to_string_lossy())
            .arg(INDEXER_MAIN_CLASS)
            .arg("--sourceroot")
            .arg(job.env.dir.to_string_lossy())
            .arg("--targetroot")
            .arg(target_root.to_string_lossy())
            .cwd(&job.env.dir);
        if !classpath.is_empty() {
            cmd = cmd.arg("--classpath").arg(classpath.join(":"));
        }
        cmd = cmd.args(target.sources.iter().map(|s| job.env.dir.join(s).to_string_lossy().to_string()));
        if !cmd.run_logged(log_path, cancel)?.success() {
            bail!("The Kotlin indexer failed for {}.", target.label);
        }
        let output = scratch.join("index.scip");
        let aggregate = Cmd::new(java)
            .arg("-jar")
            .arg(launcher.to_string_lossy())
            .arg("aggregate")
            .arg("--output")
            .arg(output.to_string_lossy())
            .arg(target_root.to_string_lossy())
            .cwd(&job.env.dir);
        if !aggregate.run_logged(log_path, cancel)?.success() || !output.exists() {
            bail!("scip-java aggregate failed for {}.", target.label);
        }
        let data = std::fs::read(&output)?;
        let index = scip::decode(&data)?;
        if let Some(parent) = cached.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = cached.with_extension("scip.tmp");
        std::fs::write(&tmp, &data)?;
        std::fs::rename(&tmp, &cached)?;
        Ok(index)
    })();
    let _ = std::fs::remove_dir_all(&scratch);
    result
}

/// Resolves every target's references through source and classpath ownership into one side's index.
/// `workspace` is the repo-relative directory the targets' paths are relative to.
pub fn resolve(targets: &[TargetIndex], workspace: &str) -> SideIndex {
    // What each target declares: symbol -> (workspace-relative file, line). A target only declares what is
    // in its own sources.
    let mut declared: Vec<HashMap<&str, (&str, u32)>> = Vec::with_capacity(targets.len());
    for t in targets {
        let sources: BTreeSet<&str> = t.target.sources.iter().map(String::as_str).collect();
        let mut map: HashMap<&str, (&str, u32)> = HashMap::new();
        for doc in t.index.documents.iter().filter(|d| sources.contains(d.path.as_str())) {
            for o in doc.occurrences.iter().filter(|o| o.is_definition() && scip::is_declaration(&o.symbol) && !scip::is_local(&o.symbol)) {
                map.entry(o.symbol.as_str()).or_insert((doc.path.as_str(), o.line));
            }
        }
        declared.push(map);
    }
    // Targets by label; a label built in several configurations prefers the referring target's own.
    let mut by_label: HashMap<&str, Vec<usize>> = HashMap::new();
    for (i, t) in targets.iter().enumerate() {
        by_label.entry(t.target.label.as_str()).or_default().push(i);
    }

    let mut found: BTreeMap<String, BTreeSet<IndexedRef>> = BTreeMap::new();
    for (ti, t) in targets.iter().enumerate() {
        // The classpath owners in the compiler's order, each once.
        let mut owners: Vec<usize> = Vec::new();
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        for entry in t.target.classpath.iter().filter(|e| !e.owner.is_empty()) {
            if !seen.insert(entry.owner.as_str()) {
                continue;
            }
            let Some(candidates) = by_label.get(entry.owner.as_str()) else { continue };
            let pick = candidates.iter().copied().find(|c| targets[*c].target.config == t.target.config).unwrap_or(candidates[0]);
            owners.push(pick);
        }
        let sources: BTreeSet<&str> = t.target.sources.iter().map(String::as_str).collect();
        for doc in t.index.documents.iter().filter(|d| sources.contains(d.path.as_str())) {
            let file = join(workspace, &doc.path);
            // Local symbols are only unique within their document.
            let mut locals: HashMap<&str, u32> = HashMap::new();
            for o in doc.occurrences.iter().filter(|o| o.is_definition() && scip::is_local(&o.symbol)) {
                locals.entry(o.symbol.as_str()).or_insert(o.line);
            }
            let out = found.entry(file.clone()).or_default();
            for o in doc.occurrences.iter().filter(|o| !o.is_definition() && scip::is_declaration(&o.symbol)) {
                let symbol = o.symbol.as_str();
                let definition: Option<(String, u32)> = if scip::is_local(symbol) {
                    locals.get(symbol).map(|line| (file.clone(), *line))
                } else {
                    // The target's own sources win, as they do for the compiler; then the classpath, in order.
                    declared[ti]
                        .get(symbol)
                        .or_else(|| owners.iter().find_map(|owner| declared[*owner].get(symbol)))
                        .map(|(path, line)| (join(workspace, path), *line))
                };
                if let Some((target_file, target_line)) = definition {
                    out.insert(IndexedRef { line: o.line, target_file, target_line, name: scip::name_of_symbol(symbol) });
                }
            }
        }
    }
    SideIndex { refs: found.into_iter().map(|(file, refs)| (file, refs.into_iter().collect())).collect(), warnings: Vec::new() }
}

/// The scip-java launcher jar: `REVIEWMAP_SCIP_JAVA` when it names a file, else the pinned release in the
/// tool cache, downloaded the first time from its GitHub release and checked against the published SHA-256.
pub fn scip_java_launcher(cancel: &Cancel, log: Log) -> Result<PathBuf> {
    if let Ok(path) = std::env::var("REVIEWMAP_SCIP_JAVA") {
        if !path.is_empty() {
            let p = PathBuf::from(&path);
            if !p.is_file() {
                bail!("REVIEWMAP_SCIP_JAVA ({path}) must name the scip-java launcher jar.");
            }
            return Ok(p);
        }
    }
    let bin = crate::store::cache_root().join("tools").join(format!("scip-java-{SCIP_JAVA_VERSION}"));
    let path = bin.join("scip-java");
    if path.is_file() {
        return Ok(path);
    }
    std::fs::create_dir_all(&bin)?;
    let curl = crate::tools::find("curl", None).ok_or_else(|| anyhow!("curl is needed to download scip-java."))?;
    log(format!("Downloading scip-java {SCIP_JAVA_VERSION} (85 MB, once)"));
    let url = format!("https://github.com/scip-code/scip-java/releases/download/{SCIP_JAVA_VERSION}/scip-java-{SCIP_JAVA_VERSION}");
    let install_log = bin.join("install.log");
    let download = bin.join("scip-java.download");
    let checksum = bin.join("scip-java.sha256");
    let fetch = |from: &str, to: &Path| -> Result<bool> {
        Ok(Cmd::new(&curl).args(["-fsSL", "-o"]).arg(to.to_string_lossy()).arg(from).cwd(&bin).run_logged(&install_log, cancel)?.success())
    };
    if !fetch(&url, &download)? || !fetch(&format!("{url}.sha256"), &checksum)? {
        bail!("Could not download scip-java. Log: {}", install_log.display());
    }
    let expected = std::fs::read_to_string(&checksum).unwrap_or_default().split_whitespace().next().unwrap_or("").to_lowercase();
    let actual = file_digest(&download)?;
    let _ = std::fs::remove_file(&checksum);
    if expected.is_empty() || expected != actual {
        let _ = std::fs::remove_file(&download);
        bail!("The downloaded scip-java does not match its published SHA-256.");
    }
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&download, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(&download, &path)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAIN_A: &str = "scip-java maven . . demo/main().";
    const HELPER: &str = "scip-java maven . . demo/helper().";
    const SHARED: &str = "scip-java maven . . demo/Shared#";

    fn target(label: &str, sources: &[&str], owners: &[&str], docs: Vec<(&str, Vec<(u32, &str, i32)>)>) -> TargetIndex {
        TargetIndex {
            target: KotlinTarget {
                label: label.to_string(),
                sources: sources.iter().map(|s| s.to_string()).collect(),
                classpath: owners.iter().map(|o| ClasspathEntry { path: format!("bazel-out/bin/{o}.jar"), owner: o.to_string() }).collect(),
                config: "k8".to_string(),
            },
            index: scip::decode(&scip::testing::encode(&docs)).unwrap(),
        }
    }

    fn refs<'a>(side: &'a SideIndex, file: &str) -> Vec<(u32, &'a str, u32)> {
        side.refs.get(file).map(|l| l.iter().map(|r| (r.line, r.target_file.as_str(), r.target_line)).collect()).unwrap_or_default()
    }

    /// Two binaries each declare `main()` and `helper()`. A reference in one must never link to the other's
    /// declaration: the symbol is the same, the owner is not.
    #[test]
    fn duplicate_symbols_resolve_to_their_own_target() {
        let a = target("//a:a", &["a/Main.kt"], &[], vec![("a/Main.kt", vec![(0, MAIN_A, 1), (1, HELPER, 1), (3, HELPER, 0)])]);
        let b = target("//b:b", &["b/Main.kt"], &[], vec![("b/Main.kt", vec![(0, MAIN_A, 1), (5, HELPER, 1), (7, HELPER, 0)])]);
        let side = resolve(&[a, b], "");
        assert_eq!(refs(&side, "a/Main.kt"), vec![(4, "a/Main.kt", 2)]);
        assert_eq!(refs(&side, "b/Main.kt"), vec![(8, "b/Main.kt", 6)]);
    }

    /// The same symbol is declared by two libraries. The user of one resolves to the library on its own
    /// classpath, not to whichever was listed first.
    #[test]
    fn references_follow_the_classpath_owner() {
        let one = target("//one:lib", &["one/Lib.kt"], &[], vec![("one/Lib.kt", vec![(2, HELPER, 1)])]);
        let two = target("//two:lib", &["two/Lib.kt"], &[], vec![("two/Lib.kt", vec![(9, HELPER, 1)])]);
        let app = target("//app:app", &["app/App.kt"], &["//two:lib"], vec![("app/App.kt", vec![(4, HELPER, 0)])]);
        let side = resolve(&[one, two, app], "");
        assert_eq!(refs(&side, "app/App.kt"), vec![(5, "two/Lib.kt", 10)]);
    }

    /// A symbol that no source or classpath owner of the referring target declares stays unresolved, even
    /// though another target of the workspace declares that name.
    #[test]
    fn no_owner_means_unresolved() {
        let lib = target("//lib:lib", &["lib/Lib.kt"], &[], vec![("lib/Lib.kt", vec![(2, HELPER, 1)])]);
        let app = target("//app:app", &["app/App.kt"], &[], vec![("app/App.kt", vec![(4, HELPER, 0)])]);
        let side = resolve(&[lib, app], "");
        assert!(refs(&side, "app/App.kt").is_empty());
        assert!(side.refs.contains_key("app/App.kt"), "the file is still covered by the index");
    }

    /// With two classpath owners of a symbol, the first in classpath order wins, as it does for the compiler.
    #[test]
    fn classpath_order_decides() {
        let one = target("//one:lib", &["one/Lib.kt"], &[], vec![("one/Lib.kt", vec![(2, SHARED, 1)])]);
        let two = target("//two:lib", &["two/Lib.kt"], &[], vec![("two/Lib.kt", vec![(9, SHARED, 1)])]);
        let app = target("//app:app", &["app/App.kt"], &["//two:lib", "//one:lib"], vec![("app/App.kt", vec![(4, SHARED, 0)])]);
        let side = resolve(&[one, two, app], "");
        assert_eq!(refs(&side, "app/App.kt"), vec![(5, "two/Lib.kt", 10)]);
    }

    /// A file that two targets compile is indexed in both; its references are the union, each resolved
    /// through the target that compiled it.
    #[test]
    fn shared_sources_keep_every_owner() {
        let one = target("//one:lib", &["one/Lib.kt"], &[], vec![("one/Lib.kt", vec![(2, HELPER, 1)])]);
        let two = target("//two:lib", &["two/Lib.kt"], &[], vec![("two/Lib.kt", vec![(9, HELPER, 1)])]);
        let x = target("//x:x", &["shared/Use.kt"], &["//one:lib"], vec![("shared/Use.kt", vec![(4, HELPER, 0)])]);
        let y = target("//y:y", &["shared/Use.kt"], &["//two:lib"], vec![("shared/Use.kt", vec![(4, HELPER, 0)])]);
        let side = resolve(&[one, two, x, y], "ws");
        assert_eq!(refs(&side, "ws/shared/Use.kt"), vec![(5, "ws/one/Lib.kt", 3), (5, "ws/two/Lib.kt", 10)]);
    }

    /// Local symbols resolve inside their own document only.
    #[test]
    fn locals_stay_in_their_document() {
        let a = target("//a:a", &["a/A.kt", "a/B.kt"], &[], vec![("a/A.kt", vec![(1, "local 0", 1), (2, "local 0", 0)]), ("a/B.kt", vec![(7, "local 0", 0)])]);
        let side = resolve(&[a], "");
        assert_eq!(refs(&side, "a/A.kt"), vec![(3, "a/A.kt", 2)]);
        assert!(refs(&side, "a/B.kt").is_empty());
    }
}
