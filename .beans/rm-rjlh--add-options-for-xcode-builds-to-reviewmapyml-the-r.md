---
# rm-rjlh
title: Add options for Xcode builds to reviewmap.yml, the request and the CLI
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:10:23Z
parent: rm-b0sh
---

Add the options an xcodebuild index needs (container, scheme, destination, configuration, extra arguments) to `reviewmap.yml`, the review request and the `reviewmap` command. Part of the xcodebuild epic (rm-b0sh).

## Why

A container with several schemes, or one that needs a particular device family or configuration, cannot be guessed. Bazel has `--target`, `--bazel-arg`, `index.targets` and `index.bazelArgs` for the same reason; today nothing equivalent exists for Xcode (`IndexConfig` in `crates/core/src/config.rs`, `ReviewRequest` in `crates/core/src/session.rs`, the flags in `crates/cli/src/main.rs`).

## What

```rust
// crates/core/src/config.rs
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct XcodeOptions {
    pub container: Option<String>,   // repo-relative .xcworkspace or .xcodeproj
    pub schemes: Vec<String>,        // YAML key `scheme`: a string or a list
    pub destination: Option<String>, // an xcodebuild destination specifier
    pub configuration: Option<String>,
    pub args: Vec<String>,           // extra xcodebuild arguments
}
```

- `IndexConfig` gains `xcode`, which accepts one mapping or a list of mappings:
  ```yaml
  index:
    xcode:
      container: ios/App.xcworkspace   # optional
      scheme: App                      # or [App, Widgets]
      destination: "generic/platform=iOS Simulator"
      configuration: Debug
      args: ["-xcconfig", "ci.xcconfig"]
  ```
- `ReviewRequest` gains `xcode: XcodeOptions` with `#[serde(default)]`, so a request written by an older `reviewmap` still parses.
- CLI flags in `crates/cli/src/main.rs`, with help text: `--scheme <name>` (repeatable), `--destination <spec>`, `--xcode-container <path>` (relative to the current directory or the repository root), `--xcodebuild-arg <arg>` (repeatable, and `--xcodebuild-arg=<arg>`).
- `pub fn xcode_options(request: &XcodeOptions, config: &Config, container: &str) -> XcodeOptions`: field by field, the request's value when set and the request names no other container; else the config entry whose `container` is this one; else the config entry without `container`.
- The request reaches the app unchanged: check `crates/cli/src/launch.rs`, `app/src-tauri/src/lib.rs`, and `app/src-tauri/src/settings.rs` (where a request is rebuilt from settings).
- README.md: the options table and the `reviewmap.yml` example.

## Acceptance criteria

- Unit tests: both YAML shapes parse; `scheme: App` and `scheme: [App, Widgets]` both fill `schemes`; a request value overrides the config; an entry with a matching `container` wins over the entry without one.
- A request JSON without `xcode` deserializes.
- `reviewmap --help` lists the four flags; `reviewmap --scheme` without a value fails with the same kind of message as `--target` without one.
- `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

None. The options are used by rm-849t.
