---
# rm-m1yk
title: Add an Xcode fixture and end-to-end tests
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-b0sh
blocked_by:
    - rm-k9ng
    - rm-849t
    - rm-9luz
---

Add a checked-in Xcode fixture and end-to-end tests that run the real `xcodebuild`, skipping when it is missing. Part of the xcodebuild epic (rm-b0sh).

## Why

The Bazel and Yarn paths each have a fixture that runs the real tool (`crates/core/tests/fixtures/swift-bazel`, `ts-yarn`; tests in `crates/core/tests/bazel_fixtures.rs`, `typescript_fixtures.rs`). The xcodebuild index (rm-849t), the components (rm-k9ng) and the stale-unit check (rm-9luz) need the same proof. CI installs no tools, so a test whose tool is missing passes early and says `skipped: …`.

## What

1. Fixture `crates/core/tests/fixtures/swift-xcode/{base,head}`, with the story of `swift-bazel` (`Store.load()` has a caller in the app, `Cache.load()` has none; head changes `Store`):
   - `Demo.xcodeproj` with macOS targets, so no simulator runtime is needed: framework `Storage` with classic file references; framework `Feed` with a synchronized folder; command-line tool `App` that depends on both and on the package product; a unit-test bundle `StorageTests`; a shared scheme `Demo` with a test action.
   - Local package `Packages/Cache` with one library target `Cache`, referenced by the project.
   - Make the project once with Xcode and commit it; no generator runs in tests. Keep it free of user data (`xcuserdata` is ignored by `.gitignore`).
2. `crates/core/tests/xcode_fixtures.rs`, using `crates/core/tests/common/mod.rs` as the other fixture tests do, with a helper that returns early with `skipped: …` when `xcodebuild -version` fails or `REVIEWMAP_SKIP_XCODE_TESTS=1`:
   - `swift_index_through_xcodebuild`;
   - `a_file_whose_target_stopped_compiling_is_not_indexed` (the rm-9luz scenario: a second review whose head changes a file and breaks another file of the same target).
3. Add the test target to `crates/core/BUILD.bazel` (with the fixture as data, like the others) and to the test list in `docs/rebuild-build.md`. Keep its home between runs as the Bazel fixture tests do (`target/reviewmap-test-home`), so a rerun is incremental.

## Acceptance criteria

With Xcode installed, `swift_index_through_xcodebuild` shows:

- report stages `preliminary` then `complete`, with no `graph` stage;
- Swift resolution `index`;
- `Store.load()` used by the app's caller, `Cache.load()` used by none;
- components `xcode:Storage`, `xcode:Feed`, `xcode:App`, the test bundle as a test component, and `spm:Cache` with kind `spmTarget` and an edge from the app;
- `analysis.workspaces` has one entry with `system: "xcode"`, `path: "Demo.xcodeproj"` and `targets: ["Demo"]`;
- the reviewed repository, `.git` included, unchanged by size and modification time (CORE-002);
- a second run reads the cached references without starting xcodebuild (no "Building" progress line).

Without Xcode both tests pass and log `skipped`. `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

Blocked by rm-k9ng, rm-849t and rm-9luz. The fixture can be made earlier and used by rm-k9ng's component tests with indexes off.
