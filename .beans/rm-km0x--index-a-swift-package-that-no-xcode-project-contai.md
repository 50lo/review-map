---
# rm-km0x
title: Index a Swift package that no Xcode project contains
status: todo
type: feature
priority: low
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-19T00:00:00Z
parent: rm-b0sh
blocked_by:
    - rm-849t
---

Optional: index a Swift package that no Xcode project or workspace contains, by running `xcodebuild` in the package's directory. Part of the xcodebuild epic (rm-b0sh), separable from it.

## Why

The xcodebuild index (rm-849t) covers local packages that an Xcode container references. A repository that is only a Swift package (a library distributed through SwiftPM) has `spm:` components from rm-k9ng but no unit, so it ends syntax-only. xcodebuild can build a package directly, so the cost is small once rm-849t exists. It is optional because "xcodebuild support" for app projects does not need it.

## What

- In `index::swift::units`, a `Package.swift` directory that no container of the Xcode model references, is a `System::Xcode` unit whose id is the package directory. It owns the files under its targets' directories that no Bazel target of the side's build graph lists (the ownership rule of rm-eeww and rm-849t: Bazel wins a file both build; without a graph the package owns all of them). A package left with no changed file of its own is not in scope.
- In `crates/core/src/index/swift/xcode.rs`, such a unit runs `xcodebuild` with the package directory as the working directory and neither `-project` nor `-workspace`. Scheme: the options' scheme; else `<package name>-Package`; else the only scheme `xcodebuild -list -json` reports (the prototype's rule, `Sources/ReviewMapCore/Swift/SwiftIndex.swift:320-330`). Destination default `generic/platform=macOS`. Everything else (DerivedData directory, flags, store, cache, restore of `Package.resolved`) as for a container.
- One fixture test: a package with two library targets and a test target.

## Acceptance criteria

- On the fixture, Swift resolution is `index` and a reference from one target to the other resolves; the test target's references are indexed.
- A package whose files are all listed by Bazel targets is not a unit. A package inside a Bazel workspace whose files no Bazel target lists is one (this repository's root `Package.swift` is such a package).
- A package that an Xcode project references is built only as part of that container.
- `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

Blocked by rm-849t. The test skips without Xcode, as the other Xcode tests do.
