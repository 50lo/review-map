---
# rm-tda2
title: Separate producing a Swift index store from reading it
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-b0sh
---

Split the Swift index code into "produce index stores" and "cache and read them", so xcodebuild can be a second producer. No behaviour change. Part of the xcodebuild epic (rm-b0sh).

## Background

`load` in `crates/core/src/index/swift.rs` (about lines 191-311) does three things in one function: looks up the cached references (`refs.json` under a key of workspace, commit, targets, Bazel arguments, toolchain and helper version); runs a Bazel build with an aspect that collects `.indexstore` directories; merges the stores and asks the Swift helper (`crates/core/src/parse/swift_helper.rs`, `IndexRequest`) to turn them into references.

## What

Turn the file into a directory:

- `crates/core/src/index/swift/mod.rs`: the job, the cache, merging stores and reading through the helper. It defines
  ```rust
  pub struct StoreBuild {
      pub stores: BTreeSet<PathBuf>,          // index store directories to read
      pub roots: Vec<IndexRoot>,              // directories index paths may start with, and the repo-relative directory each stands for
      pub prefix_map_root: Option<String>,    // what "." stands for in the store's paths (Bazel's execution root)
      pub ok: bool,                           // false: the build had errors and the index covers only what compiled
      pub log_path: PathBuf,
      pub check_unit_dates: bool,             // false for Bazel; see the stale-unit bean
  }
  pub fn load(job: &SwiftIndexJob, key_parts: &[&[u8]], produce: impl FnOnce(&Path /* cache dir */) -> Result<StoreBuild>, helper: &Mutex<SwiftHelper>, cancel: &Cancel, log: Log) -> Result<SwiftIndexResult>
  ```
  `load` returns the cached references when present; otherwise calls `produce`, reads the stores, caches the references only when `ok`, and reports `partial` when not.
- `crates/core/src/index/swift/bazel.rs`: the aspect text, `write_aspects`, `bep_files`, `index_stores`, the Bazel build with its fallbacks, returning a `StoreBuild`.
- For Bazel the key parts and their order stay as they are, so existing cached indexes hit.
- Update `crates/core/src/index/kotlin.rs` (it calls `swift::write_aspects`) and the caller in `crates/core/src/session.rs`.

## Why

The xcodebuild index (rm-849t) produces a store in a different way but needs the same cache and reader. Without the split it would copy them.

## Acceptance criteria

- `swift_index_through_bazel` and `cancelling_stops_every_bazel_command_and_ends_syntax_only` in `crates/core/tests/bazel_fixtures.rs` pass.
- A Swift index cached before the change is read after it without a Bazel build (progress line "Swift index for … : cached").
- `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md; CORE-002 and CORE-003 link to index code).

## Dependencies and constraints

None; it can be done beside rm-c26s. `check_unit_dates` is carried but unused until rm-9luz lands.
