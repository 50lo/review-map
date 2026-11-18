//! TypeScript's index, from scip-typescript, for two kinds of project:
//!
//! - **Yarn** roots, Classic (1.x) and Berry (2 and later). Dependencies are installed into the app-owned
//!   revision tree, never the reviewed working tree, with the lockfile frozen and install scripts off, as in
//!   the prototype. A Berry root is installed with the project's own Yarn release and the `node-modules`
//!   linker, whatever its `.yarnrc.yml` sets: scip-typescript's TypeScript can't resolve through
//!   Plug'n'Play, and only real `node_modules` link workspace packages to each other. From there on it is
//!   indexed as a Classic root. Yarn's own package cache is shared by every install, and the tree's
//!   `node_modules` stays between reviews unless the root is inside a Bazel workspace, where Bazel would
//!   trip over it.
//! - **Bazel workspaces that use rules_ts** (with rules_js). Nothing is installed: Bazel builds, in the
//!   app-owned tree, the npm links the scope targets depend on, which fetches and lays out their
//!   `node_modules` under bazel-bin (one query finds them; see `input_query`). For the indexer, each
//!   package directory gets a `node_modules` of links for as long as it runs: a first-party package links
//!   to its source directory, so references land in the repository's own files, and anything else to what
//!   Bazel laid out.
//!
//! scip-typescript runs through `npx` at a pinned version (`REVIEWMAP_SCIP_TYPESCRIPT` names another
//! command) with Node.js found as `tools::node` finds it, so a Finder launch works too.
//!
//! References resolve through the symbols' definitions in the repository's own files. A symbol that two
//! files define stays unresolved rather than being given to one by name. Code the index can't see makes a
//! file's references incomplete: an import of a workspace package whose entry was never built (its
//! `dist/`), of code a skipped install script or a build step would generate, or of a path no file
//! matches. scip-typescript then leaves the imported names as unresolved local symbols. Such a file is left
//! out of the index at that side, so it shows only links that syntax proves at both sides, and an
//! `index-partial` warning says which import made it so (CORE-003). Missing coverage never reads as
//! missing callers.
//!
//! Indexes are cached by the content of the project's tree, the indexer, and how it was built, so they
//! serve both sides and any checkout. One built after a failed install or build is not cached.

use super::scip;
use super::{IndexedRef, SideIndex};
use crate::analyze::SideSource;
use crate::bazel::workspace::{BazelEnv, Workspaces};
use crate::lang::typescript::project::{is_asset, Manager, Project, Resolved};
use crate::model::{Side, Warning};
use crate::parse::ParsedFile;
use crate::paths::{is_under, join, strip_dir};
use crate::proc::{log_tail, Cancel, Cmd, Log};
use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};

/// The scip-typescript release `npx` runs when `REVIEWMAP_SCIP_TYPESCRIPT` doesn't name another command.
pub const SCIP_TYPESCRIPT: &str = "@sourcegraph/scip-typescript@0.4.0";
/// The Yarn Classic release corepack or npx runs when no Yarn is installed and the project pins none.
pub const YARN_CLASSIC: &str = "yarn@1.22.22";
/// The Yarn release corepack or npx runs for a Berry root that pins no Yarn and commits none, when its
/// lockfile is in a Yarn 4 format (`__metadata.version` 8 or later).
pub const YARN_4: &str = "yarn@4.18.1";
/// The same for an older lockfile format (Yarn 2 and 3), or none.
pub const YARN_3: &str = "yarn@3.8.7";
const FORMAT: &str = "typescript-index-2";

/// How a project gets what the indexer needs.
pub enum Setup<'a> {
    /// A package-manager root: install its dependencies with `manager`, in the app-owned tree.
    Install { manager: Install, has_lockfile: bool, in_bazel_workspace: bool },
    /// A rules_ts workspace: build the targets with Bazel.
    Bazel { env: &'a BazelEnv, targets: &'a [String] },
}

/// The package manager that installs a root's dependencies, with what it needs to pick its release.
pub enum Install {
    /// Yarn Classic. `pin` is its `packageManager` field.
    YarnClassic { pin: Option<String> },
    /// Yarn Berry (2 and later). `version` is the `packageManager` pin (`yarn@4.5.0`), or `YARN_4` or
    /// `YARN_3` by the lockfile's format (`berry_version`); `yarn_path` is the release the root commits
    /// (`.yarnrc.yml`'s `yarnPath`, repo-relative), which runs first.
    YarnBerry { version: String, yarn_path: Option<String> },
}

/// The Yarn release a Berry root without a `packageManager` pin is installed with: the one that writes
/// its lockfile's format. `__metadata.version` 8 and later is Yarn 4's.
pub fn berry_version(pin: Option<&str>, lock_version: Option<u32>) -> String {
    // A root that is Berry by its `.yarnrc.yml` or lockfile may still carry a stale Classic pin, which
    // can't run a Berry install.
    match pin.filter(|p| *p != "yarn@1" && !p.starts_with("yarn@1.")) {
        Some(pin) => pin.to_string(),
        None if lock_version.is_some_and(|v| v >= 8) => YARN_4.to_string(),
        None => YARN_3.to_string(),
    }
}

/// The major release in `yarn --version`'s output (`2.4.3`).
fn reported_major(output: &str) -> Option<u32> {
    output.trim().lines().last()?.trim().split('.').next()?.parse().ok()
}

/// The major release of the Yarn that a Berry install runs, when the release can't say: the committed
/// release's, by its file name (`yarn-2.4.3.cjs`), else the version's. A name such as `yarn-berry.cjs`,
/// which `yarn set version berry` committed in the Yarn 2 days, says nothing.
fn berry_major(version: &str, yarn_path: Option<&str>) -> Option<u32> {
    let from_file = yarn_path.and_then(|p| crate::paths::file_name(p).strip_prefix("yarn-")).and_then(|v| v.split('.').next()?.parse().ok());
    from_file.or_else(|| version.trim_start_matches("yarn@").split('.').next()?.parse().ok())
}

impl Install {
    /// The package-manager part of the cache key.
    fn key(&self) -> String {
        match self {
            Install::YarnClassic { pin } => format!("yarn {}", pin.as_deref().unwrap_or(YARN_CLASSIC)),
            Install::YarnBerry { version, .. } => format!("yarn-berry {version}"),
        }
    }
}

/// How an install went. A failed one does not stop indexing: the index is built without what it would
/// have installed, says so, and is not cached.
pub struct InstallOutcome {
    pub ok: bool,
}

pub struct TypeScriptIndexJob<'a> {
    pub side: Side,
    pub sha: &'a str,
    /// Repo-relative directory of the project ("" for the root).
    pub dir: &'a str,
    /// The side's app-owned tree: the repository's root.
    pub tree_dir: &'a Path,
    pub source: &'a SideSource,
    /// The side's TypeScript files of the project, repo-relative.
    pub files: &'a [String],
    pub setup: Setup<'a>,
    /// Where logs go.
    pub log_dir: PathBuf,
    /// Called once this side's Bazel build is done (`Session::index_workspaces` starts base then).
    pub bazel_done: &'a dyn Fn(),
}

#[derive(Serialize, Deserialize, Default)]
struct Notes {
    warnings: Vec<Warning>,
}

fn short(sha: &str) -> &str {
    &sha[..sha.len().min(8)]
}

/// The command that runs scip-typescript: `REVIEWMAP_SCIP_TYPESCRIPT`, split at spaces, or npx at the
/// pinned version.
fn indexer_command(node: &Path) -> Result<(PathBuf, Vec<String>, String)> {
    if let Ok(value) = std::env::var("REVIEWMAP_SCIP_TYPESCRIPT") {
        let mut parts = value.split_whitespace().map(str::to_string);
        if let Some(program) = parts.next() {
            let path = if Path::new(&program).is_absolute() { PathBuf::from(&program) } else { crate::tools::find(&program, None).unwrap_or_else(|| PathBuf::from(&program)) };
            return Ok((path, parts.collect(), value.clone()));
        }
    }
    let npx = crate::tools::node_tool(node, "npx").ok_or_else(|| anyhow!("npx was not found next to {}.", node.display()))?;
    Ok((npx, vec!["--yes".to_string(), SCIP_TYPESCRIPT.to_string()], SCIP_TYPESCRIPT.to_string()))
}

/// The Yarn that installs a Classic project: an installed Yarn Classic, else corepack (honouring a `yarn@1`
/// pin), else npx. An installed `yarn` counts only when it runs and says it is 1.x: a global Yarn Berry, or
/// a wrapper that stands in for a Yarn that isn't installed, would not install a Classic project.
fn yarn_command(node: &Path, pin: Option<&str>, cancel: &Cancel) -> Result<(PathBuf, Vec<String>)> {
    if let Some(yarn) = crate::tools::yarn(node) {
        let path = crate::tools::node_path(node).to_string_lossy().to_string();
        let version = Cmd::new(&yarn).arg("--version").env("PATH", &path).output_string(cancel).unwrap_or_default();
        cancel.check()?;
        if version.starts_with("1.") {
            return Ok((yarn, Vec::new()));
        }
    }
    let version = pin.filter(|p| p.starts_with("yarn@1.")).unwrap_or(YARN_CLASSIC).to_string();
    if let Some(corepack) = crate::tools::node_tool(node, "corepack") {
        return Ok((corepack, vec![version]));
    }
    let npx = crate::tools::node_tool(node, "npx").ok_or_else(|| anyhow!("Yarn, corepack, and npx were not found next to {}.", node.display()))?;
    Ok((npx, vec!["--yes".to_string(), version]))
}

/// The cache key: what the indexer reads. Every file of the project's tree by content (with paths relative
/// to the project, so the key is the same wherever it sits), the indexer, and the setup.
fn cache_key(job: &TypeScriptIndexJob, indexer: &str) -> String {
    let mut parts: Vec<String> = vec![FORMAT.to_string(), indexer.to_string()];
    match &job.setup {
        Setup::Install { manager, .. } => parts.push(manager.key()),
        Setup::Bazel { env, targets } => {
            parts.push(format!("bazel {}", targets.join(" ")));
            parts.extend(env.args.iter().cloned());
        }
    }
    for (path, entry) in job.source.tree.iter().filter(|(p, _)| is_under(p, job.dir)) {
        parts.push(format!("{} {}", strip_dir(path, job.dir).unwrap_or(path), entry.oid));
    }
    crate::store::digest(parts.iter().map(String::as_bytes))
}

/// Loads the TypeScript index of one project at one side.
/// Held while Yarn or scip-typescript runs. A Bazel workspace's base is built while head is still being
/// indexed (`Session::index_workspaces`), but npx and Yarn Classic share caches that are not safe for two
/// installs at once, and each scip-typescript takes most of a gigabyte. Bazel's part runs without it.
static NODE_TOOLS: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub fn load(job: &TypeScriptIndexJob, cancel: &Cancel, log: Log) -> Result<SideIndex> {
    let at = if job.dir.is_empty() { String::new() } else { format!(" in {}", job.dir) };
    let node = crate::tools::node().ok_or_else(|| {
        anyhow!("TypeScript indexing needs Node.js, which was not found (looked on the PATH, in the usual install locations, and in Volta, nvm, fnm, mise, and asdf; REVIEWMAP_NODE names another)")
    })?;
    let (program, prefix, indexer) = indexer_command(&node)?;
    let key = cache_key(job, &indexer);
    let cache = crate::store::cache_root().join("index").join("typescript").join(&key[..2]).join(&key[2..]);
    let (index, notes) = match (std::fs::read(cache.join("index.scip")), std::fs::read(cache.join("notes.json"))) {
        (Ok(data), Ok(notes)) => {
            log(format!("TypeScript index for {} {}{at}: cached", job.side.name(), short(job.sha)));
            (scip::decode(&data)?, serde_json::from_slice::<Notes>(&notes).unwrap_or_default())
        }
        _ => build(job, &node, &program, &prefix, &cache, cancel, log)?,
    };
    let _timer = crate::proc::timer(format!("typescript resolve ({})", job.side.name()));
    Ok(resolve(job, &index, notes.warnings))
}

#[allow(clippy::too_many_arguments)]
fn build(job: &TypeScriptIndexJob, node: &Path, program: &Path, prefix: &[String], cache: &Path, cancel: &Cancel, log: Log) -> Result<(scip::Index, Notes)> {
    let at = if job.dir.is_empty() { String::new() } else { format!(" in {}", job.dir) };
    std::fs::create_dir_all(&job.log_dir)?;
    let log_path = job.log_dir.join(format!("typescript-{}-{}{}.log", job.side.name(), &job.sha[..job.sha.len().min(12)], crate::git::slug(&job.dir.replace('/', "__"))));
    let _ = std::fs::remove_file(&log_path);
    let dir = job.tree_dir.join(job.dir);
    let path = crate::tools::node_path(node);
    let path = path.to_string_lossy().to_string();
    let project = crate::lang::typescript::project(job.source);
    let mut notes = Notes::default();
    // Whether the result may be kept: not after an install or a build that failed, which may be transient.
    let mut complete = true;
    let start = std::time::Instant::now();
    let mut links = Links::default();

    match &job.setup {
        Setup::Install { manager, .. } => {
            let outcome = install(job, manager, node, &dir, &log_path, cancel, log)?;
            restore_tracked(job)?;
            if !outcome.ok {
                complete = false;
                notes.warnings.push(Warning::new(
                    "index-partial",
                    format!(
                        "TypeScript dependencies{at} could not be installed at {}, so references through third-party types may be missing. Log: {}",
                        job.side.name(),
                        log_path.display()
                    ),
                ));
            }
            if let Some(w) = skipped_scripts(&project, job.dir, &dir) {
                notes.warnings.push(w);
            }
        }
        Setup::Bazel { env, targets: scope } => {
            remove_links(&dir, &project, job.dir);
            log(format!("Finding what the TypeScript index of {} {}{at} needs Bazel to build", job.side.name(), short(job.sha)));
            let query = input_query(scope);
            append_log(&log_path, &format!("bazel query --notool_deps --output=label_kind '{query}'\n"))?;
            let found = env.command("query").what("typescript index").arg("--notool_deps").arg("--output=label_kind").arg(query).output_string(cancel);
            cancel.check()?;
            let found = match found {
                Ok(out) => Ok(IndexInputs::parse(&out)),
                Err(e) => {
                    append_log(&log_path, &format!("{e}\n"))?;
                    Err(format!("log: {}", log_path.display()))
                }
            };
            let (targets, choice) = build_targets(found, scope);
            log(format!("{} {}{at}: {choice}", job.side.name(), short(job.sha)));
            append_log(&log_path, &format!("{choice}\n\n"))?;
            log(format!("Building {} {}{at} with Bazel for the TypeScript index", job.side.name(), short(job.sha)));
            let status = env
                .command("build")
                .what("typescript index")
                .arg(format!("--disk_cache={}", Workspaces::disk_cache().display()))
                .arg("--experimental_convenience_symlinks=ignore")
                .arg("--keep_going")
                .args(env.args.iter().cloned())
                .arg("--")
                .args(targets.iter().cloned())
                .run_logged(&log_path, cancel);
            (job.bazel_done)();
            let status = status?;
            if !status.success() {
                complete = false;
                notes.warnings.push(Warning::new(
                    "index-partial",
                    format!(
                        "The Bazel build for the TypeScript index of {}{at} had errors, so some packages Bazel lays out may be missing. Files whose imports could not be resolved show only links that syntax proves. Log: {}",
                        job.side.name(),
                        log_path.display()
                    ),
                ));
            }
            let bin = env.info(&["bazel-bin"], cancel)?.remove("bazel-bin").unwrap_or_default();
            if bin.is_empty() {
                bail!("bazel info gave no bazel-bin at {}{at}. Log: {}", job.side.name(), log_path.display());
            }
            links = link_node_modules(&dir, Path::new(&bin), &project, job.dir, job.tree_dir)?;
        }
    }

    let projects = project.index_projects(job.dir);
    let output = job.log_dir.join(format!("typescript-{}-{}{}.scip.tmp", job.side.name(), std::process::id(), crate::git::slug(&job.dir.replace('/', "__"))));
    let _ = std::fs::remove_file(&output);
    log(format!("Indexing {} {}{at} with scip-typescript", job.side.name(), short(job.sha)));
    let mut cmd = Cmd::new(program).what("scip-typescript").context(job.side.name()).context(format!("{:?}", job.dir)).args(prefix.iter().cloned()).arg("index").arg("--output").arg(output.to_string_lossy()).arg("--no-progress-bar");
    cmd = if projects.is_empty() { cmd.arg("--infer-tsconfig") } else { cmd.args(projects) };
    let status = {
        let _node = NODE_TOOLS.lock().unwrap_or_else(|e| e.into_inner());
        cmd.cwd(&dir).env("PATH", &path).env("COREPACK_ENABLE_DOWNLOAD_PROMPT", "0").run_logged(&log_path, cancel)
    };
    links.remove();
    if let Setup::Install { in_bazel_workspace: true, .. } = job.setup {
        // Bazel would walk an installed node_modules on its next query of this tree.
        let _ = std::fs::remove_dir_all(dir.join("node_modules"));
    }
    let status = status?;
    if !status.success() || !output.exists() {
        let _ = std::fs::remove_file(&output);
        bail!("scip-typescript failed at {}{at}. Log: {}\n{}", job.side.name(), log_path.display(), log_tail(&log_path, 6));
    }
    let data = std::fs::read(&output)?;
    let _ = std::fs::remove_file(&output);
    let index = scip::decode(&data)?;
    if complete {
        std::fs::create_dir_all(cache)?;
        let tmp = cache.join("index.scip.tmp");
        std::fs::write(&tmp, &data)?;
        std::fs::write(cache.join("notes.json"), serde_json::to_vec(&notes)?)?;
        std::fs::rename(&tmp, cache.join("index.scip"))?;
    }
    log(format!("Indexed TypeScript at {}{at} in {}s", job.side.name(), start.elapsed().as_secs()));
    Ok((index, notes))
}

/// Installs a root's dependencies in its directory `dir` inside the app-owned tree (CORE-002), with
/// install scripts off, logging to `log_path`. What follows every install (restoring tracked files, the
/// warnings) is `build`'s.
fn install(job: &TypeScriptIndexJob, manager: &Install, node: &Path, dir: &Path, log_path: &Path, cancel: &Cancel, log: Log) -> Result<InstallOutcome> {
    let at = if job.dir.is_empty() { String::new() } else { format!(" in {}", job.dir) };
    let has_lockfile = matches!(job.setup, Setup::Install { has_lockfile: true, .. });
    let path = crate::tools::node_path(node).to_string_lossy().to_string();
    match manager {
        Install::YarnClassic { pin } => {
            let (yarn, yarn_args) = yarn_command(node, pin.as_deref(), cancel)?;
            log(format!("Installing {} {} dependencies{at} for the TypeScript index (Yarn, scripts off)", job.side.name(), short(job.sha)));
            let lockfile = if has_lockfile { "--frozen-lockfile" } else { "--pure-lockfile" };
            let _node = NODE_TOOLS.lock().unwrap_or_else(|e| e.into_inner());
            let status = Cmd::new(&yarn)
                .what("yarn install")
                .context(job.side.name())
                .args(yarn_args)
                .args(["install", lockfile, "--ignore-scripts", "--non-interactive", "--prefer-offline", "--no-progress"])
                .cwd(dir)
                .env("PATH", &path)
                .env("COREPACK_ENABLE_DOWNLOAD_PROMPT", "0")
                .env("YARN_IGNORE_ENGINES", "true")
                .run_logged(log_path, cancel)?;
            Ok(InstallOutcome { ok: status.success() })
        }
        Install::YarnBerry { version, yarn_path } => {
            let (yarn, yarn_args) = berry_command(job, node, version, yarn_path.as_deref())?;
            let _node = NODE_TOOLS.lock().unwrap_or_else(|e| e.into_inner());
            // Yarn 2 has no --mode. The release that runs says which it is.
            let reported = Cmd::new(&yarn)
                .what("yarn install")
                .context(job.side.name())
                .args(yarn_args.iter().cloned())
                .arg("--version")
                .cwd(dir)
                .env("PATH", &path)
                .env("COREPACK_ENABLE_DOWNLOAD_PROMPT", "0")
                .output_string(cancel);
            cancel.check()?;
            let major = reported.ok().as_deref().and_then(reported_major).or_else(|| berry_major(version, yarn_path.as_deref()));
            let skip = if major == Some(2) { "--skip-builds" } else { "--mode=skip-build" };
            log(format!("Installing {} {} dependencies{at} for the TypeScript index (Yarn Berry, node_modules, scripts off)", job.side.name(), short(job.sha)));
            let run = |immutable: bool| {
                Cmd::new(&yarn)
                    .what("yarn install")
                    .context(job.side.name())
                    .args(yarn_args.iter().cloned())
                    .arg("install")
                    .args(immutable.then(|| "--immutable".to_string()))
                    .arg(skip)
                    .cwd(dir)
                    .env("PATH", &path)
                    // node_modules, not Plug'n'Play, whatever the project's linker: see the module's comment.
                    .env("YARN_NODE_LINKER", "node-modules")
                    .env("YARN_ENABLE_SCRIPTS", "false")
                    .env("YARN_ENABLE_GLOBAL_CACHE", "true")
                    .env("YARN_ENABLE_TELEMETRY", "false")
                    // Yarn makes every install immutable on CI unless told otherwise.
                    .env("YARN_ENABLE_IMMUTABLE_INSTALLS", if immutable { "true" } else { "false" })
                    .env("COREPACK_ENABLE_DOWNLOAD_PROMPT", "0")
                    .run_logged(log_path, cancel)
            };
            let mut status = run(has_lockfile)?;
            if !status.success() && has_lockfile {
                // A Yarn that writes another lockfile format than the committed one (a root that pins no Yarn,
                // installed with YARN_4 or YARN_3) refuses --immutable. Without it, Yarn installs what the
                // lockfile locks and rewrites its format; `build` puts the tracked files back.
                log(format!("The immutable install of {} {}{at} failed; installing again without --immutable", job.side.name(), short(job.sha)));
                append_log(log_path, "\nThe immutable install failed; installing again without --immutable.\n\n")?;
                status = run(false)?;
            }
            Ok(InstallOutcome { ok: status.success() })
        }
    }
}

/// The Yarn that installs a Berry root: the release the project commits, run by Node.js; else corepack at
/// `version`; else npx with Yarn's npm distribution (Node.js 25 and later ship no corepack). An installed
/// global `yarn` is never used: another major would rewrite the lockfile.
fn berry_command(job: &TypeScriptIndexJob, node: &Path, version: &str, yarn_path: Option<&str>) -> Result<(PathBuf, Vec<String>)> {
    if let Some(release) = yarn_path {
        return Ok((node.to_path_buf(), vec![job.tree_dir.join(release).to_string_lossy().to_string()]));
    }
    if let Some(corepack) = crate::tools::node_tool(node, "corepack") {
        return Ok((corepack, vec![version.to_string()]));
    }
    let npx = crate::tools::node_tool(node, "npx").ok_or_else(|| anyhow!("corepack and npx were not found next to {}.", node.display()))?;
    Ok((npx, vec!["--yes".to_string(), format!("@yarnpkg/cli-dist@{}", version.trim_start_matches("yarn@"))]))
}

/// The query that finds what scip-typescript needs Bazel to build for the scope: the npm links the scope
/// depends on, which rules_js lays out as `bazel-bin/<package>/node_modules/<name>`, and generated
/// TypeScript sources (`.ts`, `.tsx`, `.mts`, `.cts`, `.d.ts`) that a `ts_project` or `js_library` in the
/// scope names in its `srcs`, directly or through the rule that generates them. The outputs of
/// `ts_project` itself are not inputs and are left out: building them would compile the TypeScript the
/// indexer reads from source. Everything else in the scope (bundles, Vite, Rust, Swift) is never read.
///
/// It is a plain query, so `select()` branches count whichever the build would take, and it runs without
/// the workspace's Bazel arguments, which are build options a query may reject (as the graph's `query`
/// does). `--notool_deps` leaves out what only the exec configuration builds: that is laid out under
/// another bin directory, not bazel-bin.
fn input_query(scope: &[String]) -> String {
    format!(
        "let d = deps(set({})) in let s = labels(\"srcs\", kind(\"ts_project|js_library\", $d)) in kind(\"npm_link_package_store\", $d) + filter(\"\\.(ts|tsx|mts|cts)$\", kind(\"generated file\", rdeps(siblings($s), $s except kind(\"ts_project\", $s), 1)))",
        scope.join(" ")
    )
}

/// What the query of `input_query` found inside the workspace, by label.
#[derive(Debug, Default, PartialEq)]
struct IndexInputs {
    /// `npm_link_package_store` targets.
    links: Vec<String>,
    /// Generated TypeScript files. They land under bazel-bin, not at their source path, so the indexer
    /// still doesn't see them; a file that imports one is left out of the index, as before.
    generated: Vec<String>,
}

impl IndexInputs {
    /// Reads `--output=label_kind` lines (`npm_link_package_store rule //app:node_modules/react`,
    /// `generated file //app:src/version.ts`). Targets in other repositories are left out: nothing of
    /// theirs is laid out in the workspace's bazel-bin.
    fn parse(out: &str) -> IndexInputs {
        let mut inputs = IndexInputs::default();
        for line in out.lines() {
            let Some((kind, label)) = line.trim().rsplit_once(' ') else { continue };
            if !label.starts_with("//") {
                continue;
            }
            match kind {
                "npm_link_package_store rule" => inputs.links.push(label.to_string()),
                "generated file" => inputs.generated.push(label.to_string()),
                _ => {}
            }
        }
        inputs.links.sort();
        inputs.links.dedup();
        inputs.generated.sort();
        inputs.generated.dedup();
        inputs
    }
}

/// The targets the TypeScript index builds, and a line for the log that says what they are. The inputs the
/// query found (`found`); or, when it failed (`found` says why) or found no npm link (generated files
/// alone lay nothing out), the scope targets, as before. A query that failed part-way gives no partial
/// set: a missing link would leave out the packages it lays out.
fn build_targets(found: Result<IndexInputs, String>, scope: &[String]) -> (Vec<String>, String) {
    let fallback = |why: String| (scope.to_vec(), format!("{why}, so Bazel builds the scope targets for the TypeScript index: {}", scope.join(" ")));
    match found {
        Err(why) => fallback(format!("The query for what the TypeScript index needs failed ({why})")),
        Ok(inputs) if inputs.links.is_empty() => fallback("The query for what the TypeScript index needs found no npm links".to_string()),
        Ok(inputs) => {
            let mut what = format!("Bazel builds {} npm {} for the TypeScript index", inputs.links.len(), if inputs.links.len() == 1 { "link" } else { "links" });
            if !inputs.generated.is_empty() {
                what.push_str(&format!(
                    " and {} generated TypeScript {} (Bazel puts {} under bazel-bin, where the indexer does not see {})",
                    inputs.generated.len(),
                    if inputs.generated.len() == 1 { "file" } else { "files" },
                    if inputs.generated.len() == 1 { "it" } else { "them" },
                    if inputs.generated.len() == 1 { "it" } else { "them" },
                ));
            }
            let targets: Vec<String> = inputs.links.into_iter().chain(inputs.generated).collect();
            let line = format!("{what}: {}", targets.join(" "));
            (targets, line)
        }
    }
}

/// Appends text to a log file.
fn append_log(path: &Path, text: &str) -> Result<()> {
    use std::io::Write;
    std::fs::OpenOptions::new().create(true).append(true).open(path)?.write_all(text.as_bytes())?;
    Ok(())
}

/// The tracked files an install may rewrite or remove: manifests, lockfiles, and Yarn Berry's Plug'n'Play
/// loader and settings (with the node-modules linker, Yarn deletes a committed `.pnp.cjs`).
const INSTALL_TOUCHES: &[&str] = &["package.json", "yarn.lock", ".pnp.cjs", ".pnp.loader.mjs", ".yarnrc.yml"];

/// Puts back every tracked file of `INSTALL_TOUCHES` under the root that an install changed or removed.
/// The tree's manifest trusts that tracked files are as it wrote them, so a later review must not see an
/// install's edits.
fn restore_tracked(job: &TypeScriptIndexJob) -> Result<()> {
    for path in job.source.tree.keys().filter(|p| is_under(p, job.dir) && INSTALL_TOUCHES.contains(&crate::paths::file_name(p))) {
        let full = job.tree_dir.join(path);
        let Some(want) = job.source.bytes(path) else { continue };
        if std::fs::read(&full).ok().as_deref() != Some(want.as_slice()) {
            if let Some(parent) = full.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&full, want)?;
        }
    }
    Ok(())
}

/// The install scripts that did not run: the project's own packages' and its direct dependencies'. Code
/// they generate is missing from the index; a file that imports it is found by its unresolved import.
fn skipped_scripts(project: &Project, root: &str, dir: &Path) -> Option<Warning> {
    let mut own: Vec<String> = Vec::new();
    for p in project.packages.iter().filter(|p| is_under(&p.dir, root)) {
        for script in p.install_scripts() {
            own.push(format!("{script} of {}", p.name.clone().unwrap_or_else(|| if p.dir.is_empty() { "the root package".to_string() } else { p.dir.clone() })));
        }
    }
    let mut deps: BTreeSet<String> = BTreeSet::new();
    let modules = dir.join("node_modules");
    let mut manifests: Vec<(String, PathBuf)> = Vec::new();
    for entry in std::fs::read_dir(&modules).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        if name.starts_with('@') {
            for inner in std::fs::read_dir(entry.path()).into_iter().flatten().flatten() {
                manifests.push((format!("{name}/{}", inner.file_name().to_string_lossy()), inner.path().join("package.json")));
            }
        } else {
            manifests.push((name, entry.path().join("package.json")));
        }
    }
    for (name, manifest) in manifests {
        if project.workspace_package(&name).is_some() {
            continue;
        }
        let Some(json) = std::fs::read(&manifest).ok().and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok()) else { continue };
        let scripts = json.get("scripts").and_then(|s| s.as_object());
        if scripts.map(|s| ["preinstall", "install", "postinstall"].iter().any(|k| s.contains_key(*k))).unwrap_or(false) {
            deps.insert(name);
        }
    }
    if own.is_empty() && deps.is_empty() {
        return None;
    }
    let mut parts: Vec<String> = Vec::new();
    if !own.is_empty() {
        parts.push(own.join(", "));
    }
    if !deps.is_empty() {
        let list: Vec<&String> = deps.iter().take(5).collect();
        parts.push(format!(
            "{} {} of dependencies ({}{})",
            deps.len(),
            if deps.len() == 1 { "install script" } else { "install scripts" },
            list.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", "),
            if deps.len() > 5 { ", …" } else { "" }
        ));
    }
    Some(Warning::new(
        "index-partial",
        format!(
            "TypeScript install scripts were not run ({}), so code they generate is missing from the index. References into it stay unresolved, and files that import it show only links that syntax proves.",
            parts.join("; ")
        ),
    ))
}

/// The `node_modules` directories made for the indexer in a Bazel workspace, removed when it is done.
#[derive(Default)]
struct Links {
    made: Vec<PathBuf>,
}

impl Links {
    fn remove(&mut self) {
        for dir in self.made.drain(..) {
            // Only links inside: removing them never follows one.
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}

impl Drop for Links {
    fn drop(&mut self) {
        self.remove();
    }
}

/// The package directories of a workspace: where rules_js links `node_modules`.
fn package_dirs(project: &Project, workspace: &str) -> BTreeSet<String> {
    let mut dirs: BTreeSet<String> = project.packages.iter().filter(|p| is_under(&p.dir, workspace)).map(|p| p.dir.clone()).collect();
    dirs.insert(workspace.to_string());
    dirs
}

/// Removes `node_modules` left in the workspace's package directories by an earlier run that stopped
/// before cleaning up. The tree never tracks them.
fn remove_links(dir: &Path, project: &Project, workspace: &str) {
    for package in package_dirs(project, workspace) {
        let rel = strip_dir(&package, workspace).unwrap_or("");
        let modules = dir.join(rel).join("node_modules");
        if std::fs::symlink_metadata(&modules).is_ok() && !project.exists(&join(&package, "node_modules")) {
            let _ = if modules.is_dir() && !modules.is_symlink() { std::fs::remove_dir_all(&modules) } else { std::fs::remove_file(&modules) };
        }
    }
}

/// Gives each package directory of the workspace a `node_modules` of links to what Bazel laid out under
/// bazel-bin, except first-party packages, which link to their sources in the tree.
fn link_node_modules(dir: &Path, bin: &Path, project: &Project, workspace: &str, tree_dir: &Path) -> Result<Links> {
    let mut links = Links::default();
    for package in package_dirs(project, workspace) {
        let rel = strip_dir(&package, workspace).unwrap_or("");
        let laid_out = bin.join(rel).join("node_modules");
        if !laid_out.is_dir() {
            continue;
        }
        let target = dir.join(rel).join("node_modules");
        if std::fs::symlink_metadata(&target).is_ok() {
            continue;
        }
        std::fs::create_dir_all(&target)?;
        links.made.push(target.clone());
        let link = |name: &str, from: &Path| -> Result<()> {
            let to = target.join(name);
            if let Some(parent) = to.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let source = match project.workspace_package(name) {
                Some(p) => tree_dir.join(&p.dir),
                None => from.to_path_buf(),
            };
            std::os::unix::fs::symlink(&source, &to)?;
            Ok(())
        };
        for entry in std::fs::read_dir(&laid_out)?.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            if name.starts_with('@') && entry.path().is_dir() && !entry.path().is_symlink() {
                for inner in std::fs::read_dir(entry.path())?.flatten() {
                    link(&format!("{name}/{}", inner.file_name().to_string_lossy()), &inner.path())?;
                }
            } else {
                link(&name, &entry.path())?;
            }
        }
    }
    Ok(links)
}

/// Resolves a project's SCIP index into one side's references, leaving out the files whose imports the
/// index could not resolve.
fn resolve(job: &TypeScriptIndexJob, index: &scip::Index, mut warnings: Vec<Warning>) -> SideIndex {
    let known: BTreeSet<&str> = job.files.iter().map(String::as_str).collect();
    let documents: Vec<(String, &scip::Document)> =
        index.documents.iter().map(|d| (join(job.dir, &d.path), d)).filter(|(f, _)| known.contains(f.as_str())).collect();
    let project = crate::lang::typescript::project(job.source);
    let (mut side, incomplete) = resolve_documents(&documents, &|file| job.source.files.get(file).cloned(), &project);
    if !incomplete.is_empty() {
        let first: Vec<String> = incomplete.iter().take(3).map(|(file, spec, why)| format!("{file} imports {spec} ({why})")).collect();
        warnings.push(Warning::new(
            "index-partial",
            format!(
                "{} TypeScript file{} at {} import{} code the index could not resolve, so only links that syntax proves are shown for {}: {}{}.",
                incomplete.len(),
                if incomplete.len() == 1 { "" } else { "s" },
                job.side.name(),
                if incomplete.len() == 1 { "s" } else { "" },
                if incomplete.len() == 1 { "it" } else { "them" },
                first.join("; "),
                if incomplete.len() > 3 { "; …" } else { "" }
            ),
        ));
    }
    side.warnings = warnings;
    side
}

/// References of the given documents (repo-relative path, document), and the files left out because an
/// import into the repository came out unresolved: (file, specifier, why).
pub fn resolve_documents(
    documents: &[(String, &scip::Document)],
    parsed: &dyn Fn(&str) -> Option<std::sync::Arc<ParsedFile>>,
    project: &Project,
) -> (SideIndex, Vec<(String, String, String)>) {
    // Where each symbol is defined: one file, or several (then it stays unresolved).
    let mut definitions: HashMap<&str, Vec<(&str, u32)>> = HashMap::new();
    for (file, doc) in documents {
        for o in doc.occurrences.iter().filter(|o| o.is_definition() && scip::is_declaration(&o.symbol) && !scip::is_local(&o.symbol)) {
            let list = definitions.entry(o.symbol.as_str()).or_default();
            if !list.iter().any(|(f, _)| *f == file.as_str()) {
                list.push((file.as_str(), o.line));
            }
        }
    }
    let mut found: BTreeMap<String, BTreeSet<IndexedRef>> = BTreeMap::new();
    let mut incomplete: Vec<(String, String, String)> = Vec::new();
    for (file, doc) in documents {
        let mut locals: HashMap<&str, u32> = HashMap::new();
        for o in doc.occurrences.iter().filter(|o| o.is_definition() && scip::is_local(&o.symbol)) {
            locals.entry(o.symbol.as_str()).or_insert(o.line);
        }
        // An import into the repository whose names came out as locals without a definition: the compiler
        // could not see what it imports.
        if let Some(parsed) = parsed(file) {
            let unresolved = parsed.imports.iter().find_map(|imp| {
                let why = match project.resolve(file, &imp.name) {
                    // An image or stylesheet: no declarations lie behind it, whatever the index made of it.
                    Resolved::Missing if is_asset(&imp.name) => return None,
                    Resolved::Missing => "no TypeScript file of the revision matches it; it may be generated".to_string(),
                    Resolved::Package { name, workspace: true, file: None } => {
                        format!("the entry of {name} is not in the repository; a build step or install script that did not run makes it")
                    }
                    Resolved::File(_) | Resolved::Package { workspace: true, .. } => "the TypeScript compiler could not resolve it".to_string(),
                    _ => return None,
                };
                let last = imp.end_line.unwrap_or(imp.line);
                doc.occurrences
                    .iter()
                    .any(|o| o.line >= imp.line && o.line <= last && !o.is_definition() && scip::is_local(&o.symbol) && !locals.contains_key(o.symbol.as_str()))
                    .then(|| (imp.name.clone(), why))
            });
            if let Some((spec, why)) = unresolved {
                incomplete.push((file.clone(), spec, why));
                continue;
            }
        }
        let out = found.entry(file.clone()).or_default();
        for o in doc.occurrences.iter().filter(|o| !o.is_definition() && scip::is_declaration(&o.symbol)) {
            let target = if scip::is_local(&o.symbol) {
                locals.get(o.symbol.as_str()).map(|line| (file.clone(), *line))
            } else {
                match definitions.get(o.symbol.as_str()).map(Vec::as_slice) {
                    Some([(f, line)]) => Some((f.to_string(), *line)),
                    _ => None,
                }
            };
            if let Some((target_file, target_line)) = target {
                out.insert(IndexedRef { line: o.line, target_file, target_line, name: scip::name_of_symbol(&o.symbol) });
            }
        }
    }
    // A file left out at one point is left out entirely, even if another project indexed it too.
    let dropped: BTreeSet<&String> = incomplete.iter().map(|(f, _, _)| f).collect();
    found.retain(|f, _| !dropped.contains(f));
    (SideIndex { refs: found.into_iter().map(|(f, r)| (f, r.into_iter().collect())).collect(), warnings: Vec::new() }, incomplete)
}

/// Why a package-manager root can't be indexed in phase 1, or None for Yarn (Classic and Berry).
pub fn unsupported(manager: &Manager, evidence: &str) -> Option<String> {
    match manager {
        Manager::YarnClassic | Manager::YarnBerry => None,
        other => Some(format!(
            "it uses {} ({evidence}), and phase 1 indexes TypeScript only in Yarn projects and in Bazel workspaces that use rules_ts",
            other.describe()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::typescript;
    use std::sync::Arc;

    fn project(files: &[(&str, &str)]) -> Project {
        let map: BTreeMap<String, String> = files.iter().map(|(p, t)| (p.to_string(), t.to_string())).collect();
        let paths: Vec<String> = map.keys().cloned().collect();
        Project::build(paths.iter(), &|p: &str| map.get(p).map(|t| t.as_bytes().to_vec()))
    }

    const STORE: &str = "scip-typescript npm @demo/lib 1.0.0 src/`store.ts`/Store#";
    const LOAD: &str = "scip-typescript npm @demo/lib 1.0.0 src/`store.ts`/Store#load().";

    /// A use resolves to the one file that defines its symbol; an import whose names came out as undefined
    /// locals leaves its file out, whatever else resolved in it.
    #[test]
    fn unresolved_imports_leave_the_file_out() {
        let p = project(&[
            ("packages/lib/package.json", r#"{"name": "@demo/lib", "types": "src/store.ts"}"#),
            ("packages/lib/src/store.ts", ""),
            ("packages/built/package.json", r#"{"name": "@demo/built", "types": "dist/index.d.ts"}"#),
            ("packages/app/src/main.ts", ""),
            ("packages/app/src/other.ts", ""),
        ]);
        let main = typescript::parse("import { Store } from \"@demo/lib\";\nexport const s = new Store().load();\n", false);
        let other = typescript::parse("import {\n  Thing,\n} from \"@demo/built\";\nimport { Store } from \"@demo/lib\";\nexport const t: Thing = new Store();\n", false);
        let encoded = scip::testing::encode(&[
            ("lib/src/store.ts", vec![(0, STORE, 1), (1, LOAD, 1)]),
            ("app/src/main.ts", vec![(0, STORE, 0), (1, STORE, 0), (1, LOAD, 0)]),
            ("app/src/other.ts", vec![(1, "local 0", 0), (3, STORE, 0), (4, "local 0", 0)]),
        ]);
        let index = scip::decode(&encoded).unwrap();
        let documents: Vec<(String, &scip::Document)> = index.documents.iter().map(|d| (join("packages", &d.path), d)).collect();
        let files: HashMap<String, Arc<ParsedFile>> = [("packages/app/src/main.ts".to_string(), Arc::new(main)), ("packages/app/src/other.ts".to_string(), Arc::new(other))].into();
        let (side, incomplete) = resolve_documents(&documents, &|f| files.get(f).cloned(), &p);
        let main_refs: Vec<(u32, &str, u32)> = side.refs["packages/app/src/main.ts"].iter().map(|r| (r.line, r.target_file.as_str(), r.target_line)).collect();
        assert_eq!(main_refs, vec![(1, "packages/lib/src/store.ts", 1), (2, "packages/lib/src/store.ts", 1), (2, "packages/lib/src/store.ts", 2)]);
        assert!(!side.refs.contains_key("packages/app/src/other.ts"), "{:?}", side.refs.keys());
        assert_eq!(incomplete.len(), 1);
        assert_eq!(incomplete[0].1, "@demo/built");
        assert!(incomplete[0].2.contains("not in the repository"), "{incomplete:?}");
    }

    /// A symbol that two files define (two unnamed projects with the same relative path) is no one's.
    #[test]
    fn a_symbol_defined_twice_stays_unresolved() {
        let p = project(&[]);
        let symbol = "scip-typescript npm . . src/`util.ts`/helper().";
        let encoded = scip::testing::encode(&[("a/src/util.ts", vec![(0, symbol, 1)]), ("b/src/util.ts", vec![(0, symbol, 1)]), ("a/src/main.ts", vec![(3, symbol, 0)])]);
        let index = scip::decode(&encoded).unwrap();
        let documents: Vec<(String, &scip::Document)> = index.documents.iter().map(|d| (d.path.clone(), d)).collect();
        let (side, incomplete) = resolve_documents(&documents, &|_| None, &p);
        assert!(side.refs["a/src/main.ts"].is_empty());
        assert!(incomplete.is_empty());
    }

    /// The query's lines become the npm links and generated TypeScript files of the workspace; other
    /// repositories' targets and other kinds are dropped.
    #[test]
    fn index_inputs_from_the_query() {
        let out = "npm_link_package_store rule //app:node_modules/react\n\
                   npm_link_package_store rule //:node_modules/@types/semver\n\
                   generated file //packages/app:src/generated/version.ts\n\
                   npm_link_package_store rule @npm//:node_modules/vite\n\
                   generated file @other//:types.d.ts\n\
                   js_library rule //app:node_modules\n\
                   npm_link_package_store rule //app:node_modules/react\n";
        let inputs = IndexInputs::parse(out);
        assert_eq!(inputs.links, ["//:node_modules/@types/semver", "//app:node_modules/react"]);
        assert_eq!(inputs.generated, ["//packages/app:src/generated/version.ts"]);
    }

    /// The index builds the links and generated files the query found, not the scope targets, and the log
    /// line names them.
    #[test]
    fn the_build_is_the_npm_links_the_scope_needs() {
        let scope = vec!["//app:bundle".to_string()];
        let inputs = IndexInputs { links: vec!["//app:node_modules/react".into(), "//app:node_modules/vite".into()], generated: vec!["//app:src/version.ts".into()] };
        let (targets, line) = build_targets(Ok(inputs), &scope);
        assert_eq!(targets, ["//app:node_modules/react", "//app:node_modules/vite", "//app:src/version.ts"]);
        assert_eq!(
            line,
            "Bazel builds 2 npm links for the TypeScript index and 1 generated TypeScript file (Bazel puts it under bazel-bin, where the indexer does not see it): //app:node_modules/react //app:node_modules/vite //app:src/version.ts"
        );
    }

    /// A failed query, or one that found no npm link, builds the scope targets as before and says so.
    #[test]
    fn without_npm_links_the_build_falls_back_to_the_scope() {
        let scope = vec!["//app:bundle".to_string(), "//app:test".to_string()];
        let (targets, line) = build_targets(Err("log: /tmp/ts.log".to_string()), &scope);
        assert_eq!(targets, scope);
        assert_eq!(line, "The query for what the TypeScript index needs failed (log: /tmp/ts.log), so Bazel builds the scope targets for the TypeScript index: //app:bundle //app:test");
        let generated_only = IndexInputs { links: Vec::new(), generated: vec!["//app:src/version.ts".into()] };
        for found in [IndexInputs::default(), generated_only] {
            let (targets, line) = build_targets(Ok(found), &scope);
            assert_eq!(targets, scope);
            assert!(line.starts_with("The query for what the TypeScript index needs found no npm links, so Bazel builds the scope targets"), "{line}");
        }
    }

    /// The Yarn Classic part of the cache key is the same as before installs had their own seam, so an
    /// index cached then is still found.
    #[test]
    fn the_yarn_classic_cache_key_is_unchanged() {
        assert_eq!(Install::YarnClassic { pin: None }.key(), "yarn yarn@1.22.22");
        assert_eq!(Install::YarnClassic { pin: Some("yarn@1.22.19".into()) }.key(), "yarn yarn@1.22.19");
    }

    /// A Berry root without a pin gets the Yarn whose lockfile format it has; its install flags follow the
    /// release that runs.
    #[test]
    fn berry_releases() {
        assert_eq!(berry_version(Some("yarn@4.5.0"), Some(6)), "yarn@4.5.0");
        assert_eq!(berry_version(None, Some(8)), YARN_4);
        assert_eq!(berry_version(None, Some(10)), YARN_4);
        assert_eq!(berry_version(None, Some(6)), YARN_3);
        assert_eq!(berry_version(None, None), YARN_3);
        assert_eq!(berry_version(Some("yarn@1.22.22"), Some(8)), YARN_4, "a stale Classic pin on a Berry root");
        assert_eq!(berry_major("yarn@3.8.7", Some(".yarn/releases/yarn-2.4.3.cjs")), Some(2));
        assert_eq!(berry_major("yarn@2.4.3", None), Some(2));
        assert_eq!(berry_major("yarn@4.5.0", Some(".yarn/releases/yarn-berry.cjs")), Some(4));
        // A committed yarn-berry.cjs names no release: the release's own --version decides.
        assert_eq!(reported_major("2.4.3\n"), Some(2));
        assert_eq!(reported_major("! Corepack is about to download …\n4.18.1\n"), Some(4));
        assert_eq!(reported_major(""), None);
        assert_eq!(Install::YarnBerry { version: "yarn@4.5.0".into(), yarn_path: None }.key(), "yarn-berry yarn@4.5.0");
    }

    #[test]
    fn unsupported_managers() {
        assert!(unsupported(&Manager::YarnClassic, "yarn.lock").is_none());
        assert!(unsupported(&Manager::YarnBerry, "it has a .yarnrc.yml").is_none());
        assert!(unsupported(&Manager::Pnpm, "pnpm-lock.yaml").unwrap().contains("uses pnpm"));
    }
}
