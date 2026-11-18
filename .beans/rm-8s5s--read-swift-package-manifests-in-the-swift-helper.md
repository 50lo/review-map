---
# rm-8s5s
title: Read Swift package manifests in the Swift helper
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-b0sh
---

Make the Swift helper report the targets, products and package dependencies of a `Package.swift`, read from its syntax. Part of the xcodebuild epic (rm-b0sh).

## Why

Most Xcode apps keep their modules in local Swift packages. Without the packages' targets, those files fall into top-level folder components, `import Core` links to nothing, and no declared dependency is known (rm-k9ng builds the components). Parsing the manifest as syntax runs no repository code, unlike `swift package dump-package`, and needs no files on disk, so it works for the preliminary report.

## What

The helper (`helper/Sources/reviewmap-swift-helper`) already parses every `.swift` blob with SwiftSyntax and returns a `ParsedFile` (`Model.swift`, mirrored by `crates/core/src/parse/mod.rs`). `Package.swift` is already among the parsed files. For a file whose name is `Package.swift`, `SwiftExtractor.parse` also fills a new optional field `manifest`:

```rust
// crates/core/src/parse/mod.rs, with #[serde(default)] on ParsedFile.manifest
pub struct PackageManifest {
    pub name: Option<String>,              // Package(name:)
    pub targets: Vec<ManifestTarget>,
    pub products: Vec<ManifestProduct>,    // .library / .executable: { name, targets: Vec<String> }
    pub dependencies: Vec<ManifestPackage>,// .package(path:) / .package(url:): { path: Option<String>, url: Option<String>, name: Option<String> }
}
pub struct ManifestTarget {
    pub name: String,
    pub kind: String,                      // "regular" | "executable" | "test" | "macro" | "plugin" | "binary" | "system"
    pub path: Option<String>,              // the `path:` argument; None means Sources/<name>, or Tests/<name> for a test
    pub dependencies: Vec<ManifestDep>,    // { name: String, package: Option<String> }: "Name", .target(name:), .product(name:package:)
    pub settings: Vec<String>,             // the text of each swiftSettings and plugins entry
}
```

Read it as the prototype's `parseManifestSyntax` does (`Sources/ReviewMapCore/Swift/SwiftComponents.swift:119-177`): function calls whose member name is `target`, `executableTarget`, `testTarget` or `macro`, with a string `name:`, that are not inside a `dependencies:` argument. Arguments that are not literals (a variable, a computed array) are skipped, except `swiftSettings` and `plugins`, whose text is kept as one entry.

The field rides the existing `parse` request and the syntax cache; there is no new helper operation. Bump `helperVersion` in `Model.swift`, which is part of the Swift syntax cache key.

## Where

`helper/Sources/reviewmap-swift-helper/SwiftExtractor.swift`, `helper/Sources/reviewmap-swift-helper/Model.swift`, `crates/core/src/parse/mod.rs`, a test in `crates/core/tests/swift_rules.rs` (it already starts the helper).

## Acceptance criteria

- A test parses a manifest with: a library target with a custom `path`, an executable target, a test target, a dependency on a product of a remote package (`.product(name: "Alamofire", package: "Alamofire")`), a local `.package(path: "../Core")`, a library product over two targets, and `swiftSettings`; it checks every field.
- `.target(name: "Core")` inside another target's `dependencies:` is a dependency, not a target.
- A Swift file that is not named `Package.swift` has `manifest == None`.
- `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

None. The helper version change invalidates the Swift syntax cache once; that is expected. If rm-9luz lands at the same time, bump the version once for both.
