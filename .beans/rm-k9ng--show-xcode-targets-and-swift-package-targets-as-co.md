---
# rm-k9ng
title: Show Xcode targets and Swift package targets as components
status: todo
type: feature
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-19T00:00:00Z
parent: rm-b0sh
blocked_by:
    - rm-tbcl
    - rm-8s5s
---

Cut Swift code that Xcode builds into components by Xcode target and Swift package target, with their modules, declared dependencies and build settings. Part of the xcodebuild epic (rm-b0sh).

## Why

`components::build` (`crates/core/src/analyze/components.rs`) makes components from Bazel targets, then each language's `Language::add_components` (only TypeScript implements it, for npm packages), then Bazel packages, then top-level folders. A Swift repository without Bazel is therefore cut into folders: `import Storage` links to nothing, no declared dependency or build-setting change is shown, and a test target is not known as test code.

## What

Implement `Language::add_components` for `SwiftLanguage` (`crates/core/src/lang/swift/`), using the Xcode model from rm-tbcl (`lang::swift::xcode::projects(source)`) and the manifests from rm-8s5s (`ParsedFile.manifest` of every parsed `Package.swift`). It handles the Swift files that no Bazel target claimed, wherever they sit, including inside a Bazel workspace: `components::build` adds Bazel targets first, so a file that both a Bazel target and an Xcode target list is the Bazel target's (the ownership rule of rm-eeww). Before the build graph arrives no Bazel target has claimed anything, so such a file is under its Xcode target in the preliminary report and moves to its Bazel target at the graph stage; review item ids start with the file path, so notes and reviewed marks survive. An Xcode or package target left with no file (Bazel owns all of them) adds no component, no `module_component` entry and no declared dependency, and a module name that both a Bazel target and an Xcode target compile stays the Bazel target's.

1. **Package targets** first. Id `spm:<name>`, or `spm:<package dir>/<name>` when the id is taken. Kind `ComponentKind::SpmTarget`. Module: the target's name. A target owns the files under `<package dir>/<path>`, where a missing `path` is `Sources/<name>`, or `Tests/<name>` for a test target; the longest directory wins. Test targets, and targets whose directory is on a test path, are test components. Plugin, binary and system targets are skipped.
2. **Xcode targets** for the files left. Id `xcode:<name>`, or `xcode:<project dir>/<name>` when taken. Kind `ComponentKind::XcodeTarget`. Module: the target's `module`. Files: the sources phase, and every Swift file under a synchronized directory minus the target's exceptions. A file in several targets goes to the best one (application, then framework or library, then other, then tests; ties by id), is recorded in `layout.shared_files` with every owner, and counts in the `shared-sources` warning (reword that warning in `components.rs` from "Bazel targets" to "targets").
3. `layout.module_component` for each module (first one wins).
4. `layout.declared_deps` (`DeclaredDep { from, to, file, symbol: "dependency <name>" }`): a target dependency to that target's component; a package product to the component of each target the product lists (the product's name when the manifest lists no products), or to `ext:<identity>` for a remote package, which also goes into `layout.externals`; a manifest dependency by name the same way. `file` is the pbxproj or the `Package.swift`.
5. `layout.target_settings` with language `swift`: Xcode targets with the model's `settings` (keys `<Configuration>: <SETTING>`) in file `<project>/project.pbxproj`; package targets with `swiftSettings: <text>` entries in their `Package.swift`. Add `key_lines: BTreeMap<String, (u32, u32)>` to `TargetSettings`, filled from the model's `setting_lines`, and make the code that places a build-settings review item's regions (`analyze/finish.rs`, which calls `settings::setting_lines`) use a key's lines when present.
6. `SwiftLanguage::contract_file`: a `*.xcconfig` file is a contract file with flag `build-settings-changed`. Its settings are not evaluated.
7. `ComponentKind` in `crates/core/src/model.rs` gains `XcodeTarget` and `SpmTarget` (serialized `xcodeTarget`, `spmTarget`: the names `app/src/languages.ts` and `app/src/Sidebar.tsx` already use). Extend the `kind` union in `app/src/types.ts`.

`SwiftLanguage::setting_flag` already maps Xcode's setting names (`SWIFT_VERSION`, `*_DEPLOYMENT_TARGET`, `SWIFT_STRICT_CONCURRENCY`, `SWIFT_UPCOMING_FEATURE_*`) to flags. The prototype's `SwiftComponents.add` (`Sources/ReviewMapCore/Swift/SwiftComponents.swift:9-58`) is the behaviour reference.

## Acceptance criteria

On the `swift-xcode` fixture (rm-m1yk; until it exists, a test repository built in the test from strings), with indexes off:

- components are the project's Xcode targets and the local package's target, with kinds `xcodeTarget` and `spmTarget` and their modules;
- `import Storage` in the app target gives an edge from the app to `xcode:Storage` that syntax proves, and the declared dependency is on the edge;
- the unit-test target is a test component;
- a remote package product gives an `ext:` component, with its pin from `Package.resolved`;
- changing `SWIFT_VERSION` in one configuration gives a build-settings review item with flag `swift:swift-version-changed` whose region is that line of the pbxproj;
- a changed `.xcconfig` gives a contract-file review item.

And: the `swift-bazel` fixture has exactly the components it had. Unit tests on `components::build` with a hand-made graph cover coexistence: a file only a Bazel target lists (Bazel target); a file only an Xcode target lists, under a root `MODULE.bazel` that uses rules_swift (`xcode:` component); a file both list (the Xcode target without a graph, the Bazel target with one); an Xcode target all of whose files Bazel owns (no `xcode:` component, and no declared dependency from it). Reviewing this repository, whose root `Package.swift` declares targets that no Bazel target builds, shows those targets as `spm:` components; that is the rule working, not a regression. `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

Blocked by rm-tbcl and rm-8s5s. It does not need the index work. Review item ids start with the file path, so notes and reviewed marks survive the change of components.
