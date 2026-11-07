---
# rm-9h2n
title: Add Cargo components and pins
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T21:23:09Z
parent: rm-wa33
---

## Implementation scope
- Add a `cargoCrate` component kind (Model.swift and viewer/src/types.ts).
- Read `Cargo.toml` with a small TOML SwiftPM package (pick one that is maintained and has no other dependencies), so name matching doesn't need Cargo installed. A workspace's `members` (with globs) and `exclude`, and a single-package repo, give the crates. Each crate's library and binaries are components; a crate with only one target is one component.
- `tests/`, `benches/`, and `examples/` go to the crate's test component. `#[cfg(test)]` modules inside source files stay in the crate but their declarations are marked as tests for the checks.
- Pins from `Cargo.lock` for the dependencies a `Cargo.toml` lists, with `[workspace.dependencies]` inheritance. Crate names with `-` are imported with `_`.
- Platform modules: `std`, `core`, `alloc`, `proc_macro`, `test`.
- Settings: features, `edition`, `rust-version`, and `[profile]` changes.

## Acceptance criteria
- [x] A workspace fixture with two crates and a binary produces the expected components, test components, and edges.
- [x] Third-party crates are external dependencies with their pinned versions.

## Summary of Changes

Added Cargo library/binary/test components, TOMLDecoder 0.4.5 (no default package dependencies), workspace membership/excludes, module-based binary file ownership, dependency aliases scoped to importing components, inherited dependency pins and build settings. Inline cfg(test) declarations remain in their crate and are classified as tests by checks and review items. Binary target names do not shadow external dependencies.

Validation: three Cargo component tests pass, including the workspace fixture, renamed dependencies, inherited settings, test edges, excluded files and binary-only dependency collision. Swift, TypeScript and Go snapshots remain unchanged. Independent review fixes and the Crossbeam binary collision regression verified. Statute and diff checks pass.
