---
# rm-l5kt
title: Add Rust index mode with rust-analyzer
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T21:25:43Z
parent: rm-wa33
---

## Implementation scope
- `RustIndex`: per side, run `cargo metadata` and `rust-analyzer scip <dir>`, then read the result with SCIP.swift. Cache per commit. A failed build script or proc macro leaves the index partial (`index-partial` in `SideIndex.warnings`), as a failed install does for TypeScript; a missing toolchain falls back to name matching.
- Measure time per side on the fixture and on the real repo from rm-z9rn; record it in docs/progress.md.
- Install a Rust toolchain with rust-analyzer in .github/workflows/ci.yml for the index test.

## Acceptance criteria
- [x] A rust-indexed fixture resolves a trait method call that name matching resolves wrongly or not at all.
- [x] Index mode on the fixture runs in CI.
- [x] Without Cargo installed, analysis completes with name matching and a warning.

## Summary of Changes

Added per-workspace Cargo/rust-analyzer SCIP indexing with commit caches, both-side fallback, and persisted partial-index diagnostics for build scripts, macros, metadata, and symbol failures. CI installs rust-analyzer and rust-src; five targeted integration tests passed, including exact trait calls, cache, missing Cargo, indexer failure, and partial-index reuse. Fixture and real Crossbeam per-side timings are recorded in docs/progress.md Step 6 notes.
