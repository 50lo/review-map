---
# rm-wb96
title: Give the TypeScript index one install seam per package manager
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-t9hw
---

Refactor the TypeScript index so that installing dependencies is one function per package manager. No behaviour change. First step of the Yarn Berry epic (rm-t9hw).

## What

In `crates/core/src/index/typescript.rs`:

- Replace `Setup::Yarn { pin, has_lockfile, in_bazel_workspace }` with `Setup::Install { manager: Install, has_lockfile: bool, in_bazel_workspace: bool }`, where for now `enum Install { YarnClassic { pin: Option<String> } }`.
- Move the install out of `build` (the `Setup::Yarn` arm, around lines 176-206) into `fn install(job: &TypeScriptIndexJob, manager: &Install, node: &Path, dir: &Path, log_path: &Path, cancel: &Cancel, log: Log) -> Result<InstallOutcome>` with `struct InstallOutcome { ok: bool }`.
- `build` keeps what follows every install: `restore_tracked`, the `index-partial` warning "TypeScript dependencies … could not be installed" when `!ok` (and `complete = false`, so the index is not cached), `skipped_scripts`, and removing `node_modules` when the root is inside a Bazel workspace.
- `cache_key` takes its package-manager part from `Install`; for Yarn Classic the text stays `yarn <pin or yarn@1.22.22>`.
- Update the caller, `Session::index_typescript` in `crates/core/src/session.rs` (it builds `Setup::Yarn` around lines 679-692).

## Why

Yarn Berry support (rm-1l2w) is a second install command with the same steps before and after it. Today the command, its flags and the lookup of Yarn are inline in `build`, so a second manager would duplicate that function.

## Acceptance criteria

- `crates/core/tests/typescript_fixtures.rs` and `typescript_index_through_bazel` in `crates/core/tests/bazel_fixtures.rs` pass unchanged.
- A Yarn Classic index cached before the change is a cache hit after it (the cache key is byte-for-byte the same for Classic).
- `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

None. Tests must pass before the refactor starts.
