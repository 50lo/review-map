---
# rm-9h2n
title: Add Cargo components and pins
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
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
- [ ] A workspace fixture with two crates and a binary produces the expected components, test components, and edges.
- [ ] Third-party crates are external dependencies with their pinned versions.
