---
# rm-tbcl
title: Read Xcode projects, workspaces and schemes from committed files
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-b0sh
---

Read Xcode projects, workspaces and shared schemes from a revision's committed files into one model, in Rust, without running any tool. Part of the xcodebuild epic (rm-b0sh).

## Why

Components (rm-k9ng), index units and scheme and destination defaults (rm-849t) all need the same facts about an Xcode project, at both base and head, before anything is built: the preliminary report is made from the object database alone (`SideSource` in `crates/core/src/analyze/mod.rs`), as TypeScript's projects already are (`crates/core/src/lang/typescript/project.rs`).

## What

Turn `crates/core/src/lang/swift.rs` into a directory module and add `crates/core/src/lang/swift/xcode.rs` with `pub fn projects(source: &SideSource) -> Arc<XcodeProjects>`, memoized with `SideSource::memo`. It reads every `*.xcodeproj/project.pbxproj` and `*.xcworkspace/contents.xcworkspacedata` in the tree, outside `config::DEFAULT_EXCLUDES` (Pods, Carthage, `.build`, …) and outside `*.xcodeproj/project.xcworkspace`. The pbxproj is parsed with the `plist` crate already in the build (`plist::Value::from_reader`; version 1.10.3 reads the OpenStep ASCII format).

```rust
pub struct XcodeProjects { pub projects: Vec<XcodeProject>, pub containers: Vec<Container> }
pub struct XcodeProject {
    pub path: String,                 // "ios/App.xcodeproj"
    pub targets: Vec<XcodeTarget>,
    pub local_packages: Vec<String>,  // repo-relative package directories (XCLocalSwiftPackageReference)
    pub unreadable: Option<String>,   // why the pbxproj could not be read
}
pub struct XcodeTarget {
    pub name: String,
    pub module: String,               // PRODUCT_MODULE_NAME when it has no "$", else the name with non-alphanumerics as "_"
    pub product_type: String,         // "com.apple.product-type.application", …
    pub is_test: bool,                // unit-test or ui-testing bundle
    pub files: Vec<String>,           // repo-relative files of the sources build phase
    pub synced_dirs: Vec<SyncedDir>,  // PBXFileSystemSynchronizedRootGroup: { dir, excluded: Vec<String> } (this target's membership exceptions)
    pub target_deps: Vec<String>,     // names of targets of the same project: PBXTargetDependency, and sibling products in the frameworks phase
    pub package_products: Vec<PackageProduct>, // { product: String, package: Local(dir) | Remote(identity) | Unknown }
    pub settings: BTreeMap<String, String>,          // "<Configuration>: <SETTING>", target values over project values
    pub setting_lines: BTreeMap<String, (u32, u32)>, // 1-based first and last line of each setting in the pbxproj text
    pub platform: Option<String>,     // SDKROOT ("iphoneos", "macosx", …)
}
pub struct Container {                // a workspace, or a project that no workspace lists
    pub path: String,
    pub projects: Vec<String>,
    pub packages: Vec<String>,        // package directories a workspace lists directly
    pub schemes: Vec<Scheme>,
}
pub struct Scheme { pub name: String, pub build_targets: Vec<String>, pub has_tests: bool }
```

- File paths resolve through the `PBXGroup` chain and `sourceTree` (`<group>`, `SOURCE_ROOT`; other source trees give no path), relative to the project's directory, normalized, and dropped when they leave the repository.
- `settings` keeps only what changes how Swift compiles or where it runs: `SWIFT_DEFAULT_ACTOR_ISOLATION`, `SWIFT_STRICT_CONCURRENCY`, `SWIFT_VERSION`, `SWIFT_APPROACHABLE_CONCURRENCY`, `OTHER_SWIFT_FLAGS`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, `IPHONEOS_DEPLOYMENT_TARGET`, `MACOSX_DEPLOYMENT_TARGET`, `SWIFT_TREAT_WARNINGS_AS_ERRORS`, `SWIFT_ENABLE_BARE_SLASH_REGEX`, `CODE_SIGN_ENTITLEMENTS`, `INFOPLIST_FILE`, `PRODUCT_BUNDLE_IDENTIFIER`, and `SWIFT_UPCOMING_FEATURE_*` (the prototype's list, `Sources/ReviewMapCore/Swift/SwiftComponents.swift:254-259`).
- `setting_lines` comes from scanning the pbxproj text: the configuration's block (`<object id> /* <name> */ = {`) and the `SETTING = …;` line inside it. The `plist` crate gives no positions.
- Remote package identity: `lang::swift::package_identity(repositoryURL)`.
- Shared schemes come from `xcshareddata/xcschemes/*.xcscheme` of the container and of its projects (XML: `BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference@BlueprintName`; `has_tests` when `TestAction/Testables` has a `TestableReference`). Use the XML reader that is already a dependency (`quick-xml` through `plist`), or add one to `Cargo.toml` and `MODULE.bazel` as `docs/rebuild-build.md` describes.

The prototype's `xcodeTargets` (`SwiftComponents.swift:181-250`) is the behaviour reference.

## Acceptance criteria

Unit tests beside the module, on pbxproj and scheme texts held as strings:

- a target with grouped file references in nested groups resolves its files' repo-relative paths;
- a target with a synchronized root group and one membership exception;
- a file listed by two targets appears in both;
- a target dependency, and a sibling framework linked without one;
- a local and a remote package product;
- a target setting overriding the project's, and each setting's line;
- `PRODUCT_MODULE_NAME = "$(TARGET_NAME)"` falls back to the sanitized name;
- a workspace that lists a project and a package gives one container; a project in no workspace is its own container;
- a malformed pbxproj gives `unreadable` and no panic.

`bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

None. Everything is read from the tree through `SideSource`, never from disk.
