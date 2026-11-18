---
# rm-849t
title: Build the Swift index with xcodebuild
status: todo
type: feature
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-19T00:00:00Z
parent: rm-b0sh
blocked_by:
    - rm-o0mk
    - rm-c26s
    - rm-tda2
    - rm-tbcl
    - rm-8s5s
    - rm-rjlh
    - rm-9luz
    - rm-eeww
---

Build the Swift index of an Xcode project with `xcodebuild`, in the app-owned tree, and read it into exact references. The central item of the xcodebuild epic (rm-b0sh).

## Why

Swift files that Bazel does not build end syntax-only: no exact references, and the checks that need them (`unused-api`, `orphaned`, `untested`, `conformers`) do not run (CORE-003 in `statute/rules/core.md`).

## What

1. **Units.** Extend `index::swift::units` (rm-c26s) with `System::Xcode` units: every container of the Xcode model (rm-tbcl: a workspace, or a project no workspace lists) that owns a changed Swift file. A container's candidates are the files of its projects' targets and the files under its local packages' directories (from the pbxproj's local package references and the workspace's package entries; target directories from the manifests of rm-8s5s). The unit's id is the container's repo-relative path.
   Bazel and Xcode can coexist in one repository, so ownership is decided per file and per side (`Units::of` takes the side, rm-c26s):
   - A Bazel target of that side's build graph lists the file in its sources: the file is in the Bazel workspace's unit, not the container's, even when an Xcode target lists it too (Bazel wins a file both build).
   - No Bazel target lists it and it is one of the container's candidates: it is in the container's unit, wherever it sits, including inside a Bazel workspace that uses Swift's rules.
   - Neither: it is in no Xcode unit and stays syntax-only, listed in `index-partial`.
   - The side has no graph for the workspace (Bazel not found, the query failed): the container owns all its candidates.
   The graph covers the review scope only, so a file whose only Bazel owner is outside the scope targets counts as not listed.
2. **Tool.** `tools::xcodebuild()` in `crates/core/src/tools.rs`: `REVIEWMAP_XCODEBUILD`, the app's settings, else `xcodebuild` as `tools::find` finds it.
3. **Options** for the unit from `xcode_options` (rm-rjlh).
   - Scheme: the options' schemes; else the container's committed shared schemes: the only one, or the one named after the container; else `xcodebuild -list -json` in the tree with the same rule. Several candidates and no match: the unit fails with a message that lists the schemes and names `--scheme` and `index.xcode.scheme`.
   - Destination: the options'; else from the `platform` of the scheme's first build target: `macosx` gives `generic/platform=macOS`, `iphoneos` `generic/platform=iOS Simulator`, `appletvos` `generic/platform=tvOS Simulator`, `watchos` `generic/platform=watchOS Simulator`, `xros` `generic/platform=visionOS Simulator`; unknown gives `generic/platform=macOS`.
4. **Build.** New `crates/core/src/index/swift/xcode.rs`, a producer of `StoreBuild` (rm-tda2). For each scheme, in the side's app-owned tree (never the reviewed repository; CORE-002):
   ```text
   xcodebuild build-for-testing            # `build` when the scheme has no test action
     -workspace|-project <tree>/<container>
     -scheme <scheme> -destination <destination> [-configuration <name>]
     -derivedDataPath <unit dir>/DerivedData
     -clonedSourcePackagesDirPath <unit dir>/SourcePackages
     -disableAutomaticPackageResolution -skipPackagePluginValidation -skipMacroValidation
     COMPILER_INDEX_STORE_ENABLE=YES CODE_SIGNING_ALLOWED=NO  <extra args>
   ```
   `<unit dir>` is `Workspaces::unit_dir(side, "xcode", container)` from rm-o0mk (`<cache>/bazel/<repo>/<side>/xcode/<slug>`), kept between reviews so the next build is incremental (the tree update rewrites only files that differ). Run with `Cmd::run_logged`, so cancelling kills the process group.
   The `StoreBuild`: `stores` = the `DataStore` directory under `<DerivedData>/Index.noindex` that has a `v5` or later directory; `roots` = the side's tree with prefix `""`; no prefix map; `ok` = every scheme's build succeeded; `check_unit_dates` = true (rm-9luz). No store at all is an error with the last lines of the log (`proc::log_tail`).
5. **Cache key parts**: a format tag, the container, the commit, the schemes, destination, configuration, extra arguments, the toolchain id (`lib_index_store` path and date, as for Bazel) and the helper version.
6. **Afterwards**: `trees::restore_tracked` for tracked `Package.resolved` files under the container and its projects.
7. **Order**: head, then base; base is skipped when head fails; no two xcodebuilds at once.
8. **Report**: `WorkspaceInfo` in `crates/core/src/model.rs` gains `system: Option<String>` (absent reads as Bazel). Each Xcode unit adds an entry: `path` the container, `targets` the schemes, `scope` `"explicit"` or `"scheme"`, `graph` `"project"`, `system` `"xcode"`.
9. **Reasons a unit has no index**, each with a test: `xcodebuild` not found; several schemes and none chosen; a `project.yml` or `Project.swift` and no committed project above the changed files ("the Xcode project is generated and not committed"); a `Podfile` next to a workspace whose `Pods/` is not in the tree; the build failed and left no store. A container that exists at one side only is built at that side only.

The prototype's xcodebuild plan (`Sources/ReviewMapCore/Swift/SwiftIndex.swift:125-142`, `findStore` at 334) is the behaviour reference.

## Acceptance criteria

- The end-to-end test of rm-m1yk passes.
- A coexistence test on the unit listing, with hand-made graphs and no tool: a repository with a root `MODULE.bazel` that uses rules_swift and `ios/App.xcodeproj`, where `//tools:Gen` lists `tools/Gen.swift`, the `App` Xcode target lists `ios/App/Main.swift`, and both list `Shared/Log.swift`. `tools/Gen.swift` and `Shared/Log.swift` are in the Bazel unit, `ios/App/Main.swift` in the Xcode unit. Without a graph, `Shared/Log.swift` and `ios/App/Main.swift` are in the Xcode unit. With `Shared/Log.swift` listed by Bazel at head only, it is in the Xcode unit at base and the Bazel unit at head.
- By hand on one real Xcode project of the user's, recorded in `docs/progress.md`: time of the first build and of a second review of another commit; cancelling during the build stops xcodebuild and its build service within a few seconds and the review ends syntax-only with "indexing was cancelled"; the reviewed repository is unchanged.
- Measured and decided, with the result written into this bean: whether a setting such as `ARCHS=<host arch>` keeps a generic simulator destination from compiling two architectures; whether `build-for-testing` fails on a scheme without a test action and whether `-skipUnavailableActions` covers it.
- `bazel test //...` passes, and the Statute `change` skill has been run, with CORE-002 and CORE-003 code links updated (AGENTS.md).

## Dependencies and constraints

- Blocked by rm-o0mk, rm-c26s, rm-tda2, rm-tbcl, rm-8s5s, rm-rjlh, rm-9luz, and by the approval of the Statute decision in rm-eeww.
- Checked on 2026-11-19 with Xcode 27.2: `xcodebuild -help` lists every flag above.
- The ownership rule above is the Statute decision of rm-eeww; if the approved text differs, this item follows the decision.
- Only targets the scheme builds are indexed; files of other targets are listed in `index-partial` by the existing coverage code. Sources of remote packages are outside the tree, so references into them are dropped.
- Index mode runs the revision's run-script phases, package plugins and macros without Xcode's validation prompt; the README says so (rm-2x16).
