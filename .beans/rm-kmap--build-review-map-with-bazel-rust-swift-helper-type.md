---
# rm-kmap
title: Build Review Map with Bazel (Rust, Swift helper, TypeScript UI, app bundle)
status: completed
type: task
priority: normal
created_at: 2026-11-15T21:31:47Z
updated_at: 2026-11-15T22:26:08Z
---

## What

Build the whole Review Map rebuild with Bazel instead of the current mix of build tools. Today each part has its own build:

- The Rust core and CLI (`crates/core`, `crates/cli`) and the Tauri backend (`app/src-tauri`) use Cargo (`Cargo.toml`, `Cargo.lock`).
- The React UI (`app/`) uses npm (`app/package.json`, `app/package-lock.json`) with Vite and Vitest.
- The Swift helper (`helper/`) uses SwiftPM (`helper/Package.swift`).
- `scripts/build-app.sh` glues these together. It builds the helper and the CLI, copies them into `app/src-tauri/binaries/`, and runs the Tauri bundle build to make `target/release/bundle/macos/Review Map.app`.

Only the Swift prototype (`Sources/`, `BUILD.bazel`, `MODULE.bazel` with rules_swift 3.6.1 and rules_swift_package_manager 1.25.0) builds with Bazel today. The prototype is the comparison baseline and must keep building.

Target state: Bazel targets for the Rust crates (rules_rust, with crates from `Cargo.lock`), the Swift helper (rules_swift), the TypeScript UI (rules_ts and rules_js), and tests for each. A Bazel target or script should produce the app bundle.

## Why

- **One build** for every part, instead of four tools and a shell script.
- **Dogfooding:** once Review Map indexes TypeScript built with Bazel, it can review its own UI code. The rebuild's phase 1 now covers TypeScript built with Bazel (rules_ts), decided on 2026-11-16 and recorded in `docs/rebuild-phase1-proposal.md`. Today the repo's TypeScript is an npm project, which phase 1 doesn't support, so Review Map can't index its own `app/` code.
- **Real-project testing:** Rust and Swift built with Bazel in this repo make it a richer test project for the Bazel paths in `crates/core/src/bazel/` (nested workspaces, scope targets, index aspects).

## Where

- `MODULE.bazel` and `BUILD.bazel` at the root, new BUILD files in `crates/core`, `crates/cli`, `app/src-tauri`, `app/` and `helper/`, and `.bazelrc` and `.bazelversion`.
- `scripts/build-app.sh`, which either calls Bazel or is replaced by a Bazel target.
- `.bazelignore`. Today it keeps Bazel out of `target/`, `app/node_modules` and the test fixtures. The nested fixture workspaces under `crates/core/tests/fixtures/` and the prototype's `Tests/` fixtures must stay ignored, because they are separate Bazel workspaces that the tests run themselves.

## Decisions to make first, and ask the user about

- **JavaScript package manager under Bazel.** rules_js normally uses a pnpm lockfile. Phase 1 supports Yarn Classic only, plus TypeScript built with Bazel. Choose between pnpm through rules_js and keeping Yarn or npm next to Bazel, and check the choice against whatever the TypeScript indexing work (branch `rebuild-typescript-indexing`) supports.
- **Tauri bundling.** The Tauri CLI expects Cargo and a frontend build. Decide whether Bazel wraps `tauri build` or builds the parts and assembles the `.app` itself, including the sidecar binaries in `app/src-tauri/binaries/`.
- **Whether Cargo and npm stay usable** for day-to-day development (rust-analyzer, `cargo test`, the Vite dev server, `REVIEWMAP_REPORT=<file> npx vite`), or Bazel becomes the only way to build.

## Acceptance criteria

- [x] `bazel build //...` builds the Rust crates, the Swift helper, the UI, and the prototype.
- [x] `bazel test //...` runs the Rust tests (unit tests and `crates/core/tests/`) and the UI tests (Vitest) and passes. The Bazel fixture tests (`crates/core/tests/bazel_fixtures.rs`) still work. They start their own Bazel in nested workspaces, so check how they behave inside a Bazel test sandbox, or keep them as Cargo-only tests with a stated reason.
  - Done as `//crates/core:bazel_fixtures`, tagged `local`, `exclusive`, `no-cache` and `requires-network`, with `HOME`, `PATH` and `JAVA_HOME` inherited. It runs outside the sandbox because its fixtures are kept out of Bazel's view by `.bazelignore`, and it keeps its home in `target/reviewmap-test-home`. On 2026-11-16 all 3 tests ran their index builds (no `skipped:` in the log), in 247 s.
- [x] One command produces a working `Review Map.app`, and the app runs a review on a fixture repository.
  - `scripts/build-app.sh` (`bazel build --config=release //app:bundle`). Checked on 2026-11-16: the layout, Info.plist and icon are the same as the `tauri build` bundle's, and the bundle is signed ad hoc. The app opened from it on the prototype's `basic` fixture showed the map, the structural checks and the code view.
- [x] Review Map, run on this repository, finds Bazel targets for `app/` and indexes its TypeScript. This needs the TypeScript indexing work merged into `rebuild` first.
  - Checked on 2026-11-16, after the TypeScript indexing work was merged into `rebuild` (`3ee28d4`, `df56a43`, `e29e1db`). The bundle's `reviewmap` command ran with a scratch `REVIEWMAP_HOME` and reviewed `f8bc240` → `3ee28d4`.
    - Review Map recognized the root workspace as rules_ts and built `//app:ts` at both sides (head 215 s, base 32 s).
    - It indexed all 50 non-test TypeScript files, so `unused-api` and `orphaned` ran.
    - `untested` was held back: 16 of 63 test files aren't covered. They belong to the prototype's nested fixture projects under `Tests/ReviewMapCoreTests/Fixtures`.
    - The `app/src` review items appear under `//app:dist` rather than `//app:ts`, because those files belong to both targets.
    - The run used the command-line tool, not the app window.
- [x] The prototype builds as it does now.
- [x] `statute check` reports no findings. Run the `statute:change` skill if code linked from rules moves.

## Decisions (asked on 2026-11-16, answered by the user)

- **JavaScript packages:** switch to a pnpm lockfile. `app/pnpm-lock.yaml` was made with `pnpm import` from `app/package-lock.json`, with the same 232 packages at the same versions, and `package-lock.json` was removed. rules_js reads it through `npm_translate_lock`, so Review Map can index the UI (rules_ts + rules_js, decided in `docs/rebuild-phase1-proposal.md` on the TypeScript branch).
- **Tauri bundling:** Bazel builds every part (`//app:dist` with Vite, `//app/src-tauri:reviewmap-app` with rules_rust, `//crates/cli:reviewmap`, `//helper:reviewmap-swift-helper`), and a Starlark rule (`app/macos_app.bzl`) assembles the `.app` as `tauri build` did. The Tauri CLI is not used.
- **Bazel only:** Bazel is the only supported build. Cargo files stay as crate_universe's input. `helper/Package.swift` and `helper/Package.resolved` were removed, because the helper uses the root `Package.swift` pins. rust-analyzer gets `rust-project.json` from `gen_rust_project`. `tauri dev` is gone; the UI dev server is `bazel run //app:dev`.

How to build and test is in `docs/rebuild-build.md`.

## Dependencies and constraints

- Work on a branch cut from `rebuild`, the long-running branch for the rebuild, and merge it back into `rebuild` when done.
- The TypeScript indexing session (branch `rebuild-typescript-indexing`) should land first, or at least settle the package manager question, so this work matches what Review Map can index.
- Rules in `statute/` (CORE-001 to CORE-006) must keep holding. In particular, CORE-002 says analysis never writes into the reviewed repo.
- On this machine, `npm` is aliased to `pmg npm` and skips install scripts.
