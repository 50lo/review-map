---
# rm-2x16
title: Show and document Xcode units in the app and README
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-b0sh
blocked_by:
    - rm-849t
---

Make the app's status line and the documentation describe Xcode reviews correctly. Part of the xcodebuild epic (rm-b0sh).

## Why

After the xcodebuild index (rm-849t) a review can have Xcode units and no Bazel at all, but the UI and docs still describe a Bazel-only tool: `app/src/Shell.tsx` (about line 224) sets `bazel = analysis.workspaces.length > 0 || …` to decide whether the status explanation mentions a build-graph step, and with Xcode entries in `analysis.workspaces` that becomes true for a review that has no such step. The README says "direct Xcode builds are outside phase 1".

## What

- `app/src/types.ts`: `WorkspaceInfo.system?: "bazel" | "xcode" | string` (absent means Bazel), matching `WorkspaceInfo.system` in `crates/core/src/model.rs`.
- `app/src/Shell.tsx`: `bazel` is true only when a workspace entry's system is Bazel (or absent) or a component has kind `bazelPackage`. Check every other reader of `analysis.workspaces`.
- README.md:
  - Requirements: Xcode is also what builds projects reviewed through xcodebuild.
  - "Languages" table: Swift projects are Bazel (rules_swift) and Xcode projects with their local Swift packages; index mode for Xcode: `xcodebuild` builds the scheme with indexing on, in the app's copy, and the app reads the index store.
  - Options table and `reviewmap.yml` example: `--scheme`, `--destination`, `--xcode-container`, `--xcodebuild-arg`, `index.xcode`.
  - The sentence listing what is outside phase 1: remove direct Xcode builds; say that generated projects (XcodeGen, Tuist) and CocoaPods workspaces are not indexed.
  - One paragraph: index mode runs the reviewed revision's build, including Xcode run-script phases, package plugins and macros (accepted without Xcode's validation prompt), in the app's copy of the repository.
  - "Where data lives": DerivedData is kept under the cache per repository and removed with it when idle.
- `docs/rebuild-phase1-proposal.md`: move "direct Xcode build orchestration" out of the excluded list, with the date.

## Acceptance criteria

- `bazel test //app/...` passes, with a test for the status explanation of a report whose only workspace entry has `system: "xcode"` (no build-graph wording).
- The app on the Xcode fixture's report (`REVIEWMAP_REPORT=<report.json> bazel run //app:dev`; fixture from rm-m1yk) shows Xcode and SPM targets with their kind names ("Xcode target", "SPM target") and the Swift icon, checked in light and dark mode.
- The Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

Blocked by rm-849t.
