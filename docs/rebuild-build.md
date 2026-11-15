# Building the rebuild

The rebuild (see [rebuild-phase1-proposal.md](rebuild-phase1-proposal.md)) builds with Bazel only, in the same workspace as the Swift prototype. Bazel fetches Rust, Node.js and every package itself. You need Bazel or Bazelisk (`.bazelversion` pins Bazel 9.3.1) and full Xcode, for Swift and libIndexStore.

| Part | Where | Bazel rules | Dependencies from |
| --- | --- | --- | --- |
| Core and the `reviewmap` command | `crates/core`, `crates/cli` | rules_rust | `Cargo.toml` and `Cargo.lock`, read by crate_universe |
| App (Tauri 2) | `app/src-tauri` | rules_rust | the same |
| UI (React, Vite, Vitest) | `app/` | rules_js, rules_ts | `app/pnpm-lock.yaml` |
| Swift helper | `helper/` | rules_swift | the prototype's `Package.swift` and `Package.resolved` |
| App bundle | `app/macos_app.bzl` | a small rule of this repo | the three executables above |

## Commands

```bash
bazel build //...                                  # everything, the prototype included
bazel test //...                                   # Rust tests, the UI's Vitest tests, the Bazel fixture tests
scripts/build-app.sh                               # Review Map.app, optimized; prints where it is
scripts/build-app.sh --install                     # also copies it to ~/Applications, links ~/.local/bin/reviewmap
REVIEWMAP_REPORT=<report.json> bazel run //app:dev # the UI in a browser, with reloads (app/dev.mjs)
bazel run @rules_rust//tools/rust_analyzer:gen_rust_project  # rust-project.json for rust-analyzer
```

`scripts/build-app.sh` runs `bazel build --config=release //app:bundle`. The bundle is in Bazel's output tree (`bazel-out/<config>/bin/app/Review Map.app`), and is read-only there.

## How the parts fit

- **Rust.** crate_universe reads the workspace's `Cargo.toml` and `Cargo.lock`, which stay the record of the Rust dependencies: add one to a `Cargo.toml` (or change its version requirement), and the next `bazel build` updates `Cargo.lock` with the Cargo that rules_rust fetched; commit both, with `MODULE.bazel.lock`. Cargo is not used to build or test.
- **The app without the Tauri CLI.** Tauri's build script and `generate_context!()` read `app/src-tauri/tauri.conf.json`. The BUILD file passes `TAURI_CONFIG`, which Tauri merges into that file, to point `frontendDist` at the UI that `//app:dist` built, and the app's `tauri` dependency turns on `custom-protocol`, as `tauri build` does, so the app serves the UI it embeds instead of loading `build.devUrl`. `//app:bundle` then makes the bundle `tauri build` made: `Contents/MacOS` holds `reviewmap-app`, `reviewmap` and `reviewmap-swift-helper`, with `icon.icns` and an `Info.plist` with the same keys, and the bundle is signed ad hoc.
- **The UI's packages.** `app/package.json` lists them and `app/pnpm-lock.yaml` pins them; there is no `package-lock.json`. rules_js lays them out under `bazel-bin/app/node_modules` and never runs their install scripts (`pnpm.onlyBuiltDependencies` is empty). To add or bump a package, edit `package.json` and update the lockfile with Bazel's pnpm: `bazel run -- @pnpm//:pnpm --dir $PWD/app install --lockfile-only`. `//app:ts` is the type check (`tsc --noEmit`) and the target that holds the UI's TypeScript, which is what Review Map builds when it indexes a change to `app/`.
- **The Swift helper** uses the prototype's Swift packages: swift-syntax 602.0.0 and indexstore-db at swift-6.2.4-RELEASE, the pins in the root `Package.resolved`. Change them there.
- **Version.** `version.bzl` holds the version for the Bazel targets. Keep it equal to `Cargo.toml`, `app/package.json` and `tauri.conf.json`.

## Tests

`bazel test //...` runs:

- `//crates/core:unit_tests`, `//crates/core:core_rules`, `//crates/core:swift_rules` and `//app/src-tauri:unit_tests`, in the sandbox. The acceptance tests read their fixtures as runfiles, and run the Swift helper that Bazel built (`REVIEWMAP_SWIFT_HELPER`).
- `//app:test`, the UI's Vitest tests, which read the prototype's reports in `Tests/ReviewMapCoreTests/Fixtures`.
- `//crates/core:bazel_fixtures`, the index builds from start to end. They start Bazel in nested workspaces made from fixtures that `.bazelignore` keeps out of this workspace (`crates/core/tests/fixtures`, and the prototype's `kotlin-bazel-indexed`). So the target runs outside the sandbox (`local`), one at a time (`exclusive`), is never cached (`no-cache`), reads the fixtures from the checkout, keeps the app's home in `target/reviewmap-test-home` so the nested Bazel servers and output bases stay warm, and inherits `PATH`, `HOME` and `JAVA_HOME` to find Bazel, the JDK and Xcode. A test whose tool is missing passes early and says `skipped: …` in its log (`bazel-testlogs/crates/core/bazel_fixtures/test.log`); `REVIEWMAP_SKIP_BAZEL_TESTS=1` skips them all (`--test_env=REVIEWMAP_SKIP_BAZEL_TESTS=1`).

## What is gone

- Cargo, npm and SwiftPM as ways to build: `helper/Package.swift` and `app/package-lock.json` are removed, and the code no longer looks for `helper/.build` or Cargo's `target/` directory. The CLI finds the app, and the core finds the helper, next to themselves in Bazel's output tree.
- `tauri dev`, the app window with the UI reloading from Vite: the app always embeds the UI it was built with. Work on the UI in a browser with `bazel run //app:dev`, and rebuild the app to see it there.
