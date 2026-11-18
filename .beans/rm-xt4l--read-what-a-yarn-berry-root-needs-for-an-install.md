---
# rm-xt4l
title: Read what a Yarn Berry root needs for an install
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-t9hw
---

Read, from committed files, what a Yarn Berry (Yarn 2, 3, 4) root needs before its dependencies can be installed, and stop treating Berry's workspace entries as pinned packages. Part of the Yarn Berry epic (rm-t9hw).

## What

1. Extend `InstallRoot` in `crates/core/src/lang/typescript/project.rs` (the struct around line 252, filled by `Project::find_roots`) with:
   - `yarn_path: Option<String>`: the `yarnPath` of the root's `.yarnrc.yml`, as a repo-relative path, only when that file exists in the revision's tree (for example `.yarn/releases/yarn-4.5.0.cjs`).
   - `lock_version: Option<u32>`: `__metadata.version` of the root's `yarn.lock`.
   - `yarn_pin` stays as it is (the `packageManager` field without its `+sha…` suffix).
   Parse `.yarnrc.yml` with `serde_yaml_ng`, already a dependency of the crate.
2. In `pins` in `crates/core/src/lang/typescript/mod.rs` (the `"yarn.lock"` arm, around line 383), skip an entry whose version is `0.0.0-use.local`. That is how a Berry lockfile lists a workspace package (`"@demo/lib@workspace:packages/lib"`).

## Why

The Berry install (rm-1l2w) must run the Yarn release the project uses, or `yarn install --immutable` fails because another major would rewrite the lockfile. A first-party workspace package must not show up as a pinned external package in the report's external dependency changes.

## Acceptance criteria

Unit tests in the two files:

- A root with `.yarnrc.yml` containing `yarnPath: .yarn/releases/yarn-4.5.0.cjs`, and that file in the tree, gives `yarn_path == Some(".yarn/releases/yarn-4.5.0.cjs")` (prefixed by the root's directory when the root is not the repository root).
- A `yarnPath` that names a file not in the tree gives `None`.
- A `yarn.lock` starting with `__metadata:\n  version: 8` gives `lock_version == Some(8)`; a Classic lockfile gives `None`.
- A Berry lockfile with `"@demo/lib@workspace:packages/lib":` and `version: 0.0.0-use.local` gives no pin for `@demo/lib`, even when a package.json lists it as a dependency.
- The existing `managers`, `resolution` and `lockfile_pins` tests pass (update the `InstallRoot` literal in `resolution`).
- `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

None. Everything is read from the revision's tree, never from disk.
