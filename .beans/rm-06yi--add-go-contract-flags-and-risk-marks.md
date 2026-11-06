---
# rm-06yi
title: Add Go contract flags and risk marks
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T01:30:00Z
parent: rm-a4b7
---

## Implementation scope
- `GoFlags`, like TypeScriptFlags.swift: exported API added or removed, signature changes of exported declarations, interface method set changes, struct field tag changes (`json:`, `yaml:`, `db:`), struct fields added or removed on exported types, and exported names becoming unexported.
- `settingFlag` for `go.mod` directives (`go-version-changed`, `toolchain-changed`, `replace-changed`) and `flagRisk` weights.
- Risk table as tree-sitter queries with the language-neutral kinds: `go` statements (concurrency), `panic` and `log.Fatal` (crash), `recover` (flow), ignored errors (`_ =` or `_, _ :=` where the dropped value is an error, and calls whose error result is discarded where the query can tell), type assertions without `ok` (crash), and `unsafe` (crash).
- `isViewCode` is false.
- Add the new flags to the viewer's `flagWeight` in viewer/src/graph.ts.

## Acceptance criteria
- [x] Fixture changes produce the expected flags and risk marks, each covered by a test.
- [x] Region risk on the fixture ranks a new goroutine and an ignored error above a body-only change.
