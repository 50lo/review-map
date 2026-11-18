---
# rm-o0mk
title: Move the app-owned trees out of the Bazel module
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-b0sh
blocked_by:
    - rm-1l2w
---

Move the app-owned base and head trees out of the Bazel module into a module of their own, with the helper that restores tracked files. No behaviour change. Part of the xcodebuild epic (rm-b0sh).

## Background

For each reviewed repository the app keeps one base and one head copy of the revision outside that repository (`<cache>/bazel/<repo>/<side>/tree`, with `manifest.json` and a `lock` file), because builds and installs need real files and must never write into the reviewed repository (CORE-002 in `statute/rules/core.md`). The code is `Workspaces` in `crates/core/src/bazel/workspace.rs`. Bazel uses the trees, Yarn installs use them, and xcodebuild will (rm-849t).

## What

- New `crates/core/src/trees.rs` with what is not Bazel's: `Workspaces::acquire` (the lock), `root`, `tree_dir`, `materialize`, the `Manifest`.
- `output_base`, `workspace_dir`, `disk_cache`, `BazelEnv`, `OUTPUT_BASES` and `shutdown_all` stay in `bazel::workspace` (as functions that take the trees where needed).
- Move `restore_tracked` from `crates/core/src/index/typescript.rs` to `trees.rs` as `pub fn restore_tracked(tree_dir: &Path, source: &SideSource, keep: &dyn Fn(&str) -> bool) -> Result<()>`: for every tracked path that `keep` accepts, rewrite the file when its content differs from the blob or it is missing.
- Add `fn unit_dir(&self, side: Side, system: &str, unit: &str) -> PathBuf` returning `<root>/<side>/<system>/<slug(unit)>`, for per-unit build data (xcodebuild's DerivedData).
- Move the `Trees` struct and `Session::trees` in `crates/core/src/session.rs` to use the new module.
- The on-disk layout does not change: the root stays `<cache>/bazel/<repo>`, so existing Bazel output bases stay warm and `store::evict_idle_workspaces` keeps removing the whole repository directory.

## Why

Three callers share the trees and two more need `restore_tracked` (a tool that rewrites a tracked file would otherwise leave the next review a tree that differs from its manifest). Keeping them in the Bazel module forces non-Bazel code to reach into it.

## Where

`crates/core/src/bazel/workspace.rs`, new `crates/core/src/trees.rs`, `crates/core/src/lib.rs`, `crates/core/src/session.rs`, `crates/core/src/index/{typescript,swift,kotlin}.rs`, `crates/cli/src/main.rs` and `app/src-tauri/src/lib.rs` if they name moved items, `crates/core/BUILD.bazel` if it lists sources.

## Acceptance criteria

- Every test passes with no change to test code beyond import paths.
- A repository reviewed before the change reuses its tree and output bases afterwards: the progress line "Updating the … workspace to …" reports only the files that differ between the commits.
- CORE-002's scope names index builds: the Statute `change` skill has been run and its code links updated (AGENTS.md).

## Dependencies and constraints

Blocked by rm-1l2w, which generalizes `restore_tracked`, so the function moves once. Tests must pass before the refactor starts.
