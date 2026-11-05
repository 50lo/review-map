---
# rm-l5kt
title: Add Rust index mode with rust-analyzer
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-wa33
---

## Implementation scope
- `RustIndex`: per side, run `cargo metadata` and `rust-analyzer scip <dir>`, then read the result with SCIP.swift. Cache per commit. A failed build script or proc macro leaves the index partial (`index-partial` in `SideIndex.warnings`), as a failed install does for TypeScript; a missing toolchain falls back to name matching.
- Measure time per side on the fixture and on the real repo from rm-z9rn; record it in docs/progress.md.
- Install a Rust toolchain with rust-analyzer in .github/workflows/ci.yml for the index test.

## Acceptance criteria
- [ ] A rust-indexed fixture resolves a trait method call that name matching resolves wrongly or not at all.
- [ ] Index mode on the fixture runs in CI.
- [ ] Without Cargo installed, analysis completes with name matching and a warning.
