---
# rm-gpmo
title: Add Go index mode with scip-go
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T01:30:00Z
parent: rm-a4b7
---

## Implementation scope
- `GoIndex`, like TypeScriptIndex.swift: per side, run `go mod download` (failures go to `SideIndex.warnings` as `index-partial`), then `scip-go`, and read the result with SCIP.swift. Cache per commit, as for the other languages.
- Find scip-go on PATH, or install it with `go install github.com/sourcegraph/scip-go/cmd/scip-go@<pinned version>` into a cache folder. A missing Go toolchain makes the language fall back to name matching, as an index failure does.
- Install Go and scip-go in .github/workflows/ci.yml for the index test.

## Acceptance criteria
- [x] A go-indexed fixture resolves a reference that name matching gets wrong (two packages declaring the same name).
- [x] Index mode on the fixture runs in CI.
- [x] Without Go installed, analysis completes with name matching and a warning.
