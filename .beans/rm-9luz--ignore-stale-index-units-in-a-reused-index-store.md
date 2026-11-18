---
# rm-9luz
title: Ignore stale index units in a reused index store
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-b0sh
---

Make the Swift helper leave out a file whose index data is older than the file, when the caller asks for it. Part of the xcodebuild epic (rm-b0sh).

## Why

The xcodebuild index (rm-849t) keeps one DerivedData per repository, side and container between reviews, so that builds are incremental. Its index store (`Index.noindex/DataStore`) then can hold a unit that was written for an older content of a file which the last build did not compile again: the scheme no longer builds its target, or the build failed before reaching it. Reading that unit would show references from the wrong content as exact, which CORE-003 (`statute/rules/core.md`) forbids. Leaving the file out makes it "not indexed", which the report already says honestly through `index-partial` and held-back checks. Bazel's stores do not have the problem: they are collected fresh from the build's declared outputs.

## What

- `IndexRequest` gains `checkUnitDates: Bool`, default false, in `helper/Sources/reviewmap-swift-helper/IndexReader.swift` and as `check_unit_dates` in `crates/core/src/parse/swift_helper.rs` (serialized camelCase, as the other fields).
- When it is true, `IndexReader.read`:
  - skips a requested file when `db.dateOfLatestUnitFor(filePath:)` is nil or earlier than the file's modification time on disk (the file is then not emitted, exactly like a file without index data);
  - does not resolve a reference to a definition whose file fails the same check (cache the answer per path).
- Bump `helperVersion` in `helper/Sources/reviewmap-swift-helper/Model.swift`.
- The Bazel producer leaves the flag off.

`dateOfLatestUnitFor(filePath:)` exists in IndexStoreDB at the pinned revision (checked 2026-11-19 in the fetched package, `Sources/IndexStoreDB/IndexStoreDB.swift`).

## Acceptance criteria

- The scenario in the Xcode fixture tests (rm-m1yk): review A builds the index; review B's head changes a file and adds a syntax error to another file of the same target, so the target fails to compile; in B the changed file has no index references at head and is listed in `index-partial`, while files of targets that still compile are indexed.
- `swift_index_through_bazel` in `crates/core/tests/bazel_fixtures.rs` passes with the flag off.
- `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

None; it can merge before the xcodebuild index. If rm-8s5s lands at the same time, bump the helper version once for both. A file that did not change but left its target keeps a unit that is still true to its content; that is accepted.
