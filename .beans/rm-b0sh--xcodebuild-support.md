---
# rm-b0sh
title: xcodebuild support
status: todo
type: epic
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-19T00:00:00Z
---

Review Swift projects that are built by Xcode (an `.xcodeproj` or `.xcworkspace`, with their local Swift packages), not only by Bazel: components from the committed project files, and exact references from an index that `xcodebuild` builds.

## Why

The Rust core (`crates/core`) indexes Swift only in Bazel workspaces. A Swift repository without Bazel is cut into top-level folders and ends syntax-only with "the change touches no Bazel workspace, and phase 1 indexes Bazel projects only". The prototype (`Sources/ReviewMapCore/Swift/SwiftComponents.swift`, `SwiftIndex.swift`) had Xcode and SwiftPM components and an xcodebuild index; it is the behaviour reference, not code to keep.

## What makes it hard today (found 2026-11-19)

- `Session::refine` (`crates/core/src/session.rs`) is one function with a hard-coded block per language; Swift and Kotlin are "Bazel only".
- A build unit has no build system, and a file is given to a Bazel workspace by containment alone.
- `crates/core/src/index/swift.rs` mixes the Bazel build with the cache and the index-store reader.
- The app-owned base and head trees live in `crates/core/src/bazel/workspace.rs`, though Yarn uses them and xcodebuild will.
- Options and `analysis.workspaces` in the report only know Bazel.

The analyzer (`crates/core/src/analyze`), the `Language` trait, `SideIndex`, the helper's store reader and the UI's language table need no redesign; the UI already has the `spmTarget` and `xcodeTarget` component kinds.

## Decisions (planned 2026-11-19)

- **Who claims a file.** Ownership decides, per file and per side: a file that a Bazel target of the review scope lists is indexed by Bazel; any other Swift file that an Xcode target or local package owns is indexed by its Xcode container, wherever it sits; a file both build is Bazel's; a file neither owns is syntax-only. So in a repository where both coexist, each file follows the build that owns it, and without a Bazel graph Xcode takes the files both build. A Bazel workspace is queried for a language only when it uses that language's rules (Swift: rules_swift, rules_apple, rules_xcodeproj, rules_swift_package_manager). An Xcode container is a workspace, or a project no workspace contains. Recorded as a Statute decision in rm-eeww.
- **Components need no build.** Xcode targets come from `project.pbxproj`, parsed in Rust with the `plist` crate (1.10.3 reads the ASCII format). Swift package targets come from `Package.swift` syntax, parsed by the Swift helper; no repository code runs. So an Xcode review has final components in the preliminary report.
- **The index.** One `xcodebuild` per container and side, in the app-owned tree, into a DerivedData kept per repository, side and container so later builds are incremental. The store (`Index.noindex/DataStore`) is read by the existing helper, which ignores index units older than their source file.
- **Not in the first version**, each reported as the reason a unit has no index: generated projects that are not committed (XcodeGen, Tuist), workspaces that need `pod install`. `.xcconfig` files are not evaluated. Objective-C stays a coverage gap.
- Index mode runs the reviewed revision's run-script phases, package plugins and macros, and passes `-skipPackagePluginValidation -skipMacroValidation`. Accepted, as Bazel actions already are; the README says so.
- DerivedData can reach several GB per side; it is removed with the repository's other app-owned data after the idle limit (`store::evict_idle_workspaces`).

## Facts checked on 2026-11-19

- Xcode 27.2 on the Mac mini: `xcodebuild -help` lists `-derivedDataPath`, `-clonedSourcePackagesDirPath`, `-disableAutomaticPackageResolution`, `-skipPackagePluginValidation`, `-skipMacroValidation`, `-skipUnavailableActions`, `-list -json`, `-showBuildSettings -json`. One iOS 18.0 simulator runtime is installed.
- IndexStoreDB at the pinned revision has `dateOfLatestUnitFor(filePath:)`.

## Order

1. Refactors, no behaviour change: rm-o0mk (trees), rm-c26s (build units, split `refine`), rm-tda2 (Swift store producer and reader). rm-eeww in parallel.
2. Components: rm-tbcl (pbxproj), rm-8s5s (Package.swift), rm-k9ng (components).
3. Index: rm-rjlh (options), rm-9luz (stale units), rm-849t (xcodebuild), rm-m1yk (fixture and tests), rm-2x16 (UI and docs).
4. Optional: rm-km0x (standalone Swift packages).

## Done when

A review of an Xcode project with local packages shows Xcode and package targets as components, ends with Swift resolution `index`, and writes nothing into the reviewed repository.
