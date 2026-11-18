# Building the rebuild

The rebuild (see [rebuild-phase1-proposal.md](rebuild-phase1-proposal.md)) builds with Bazel only, in the same workspace as the Swift prototype. Bazel fetches Rust, Node.js and every package itself. You need Bazelisk (`.bazelversion` pins Bazel 9.3.1) and full Xcode, for Swift and libIndexStore. Bazelisk runs `tools/bazel`, described below; a plain Bazel binary skips it.

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
- **Xcode updates.** Bazel detects Xcode once (`@local_config_xcode`, `@local_config_apple_cc`) and detects it again only when `DEVELOPER_DIR` or `XCODE_VERSION` changes; an Xcode updated in place changes neither, and the build then fails until `bazel clean --expunge`. `tools/bazel`, which Bazelisk runs in place of Bazel, sets `XCODE_VERSION` to the selected Xcode's path and build number (from its `version.plist`) unless it is already set. Neither rule reads the value, so an Xcode update or `xcode-select -s` only redoes the detection, in about 2 s, and every build action stays cached. Bazelisk puts `tools/` first on the `PATH` it gives the wrapper, so the wrapper takes it off again before it runs Bazel; otherwise tests that start Bazel in other workspaces would find the wrapper as `bazel`. Run without `BAZEL_REAL`, it hands over to the next `bazel` on the `PATH`.
- **Version.** `version.bzl` holds the version for the Bazel targets. Keep it equal to `Cargo.toml`, `app/package.json` and `tauri.conf.json`.

## Tests

`bazel test //...` runs:

- `//crates/core:unit_tests`, `//crates/core:core_rules`, `//crates/core:swift_rules`, `//crates/core:llm` and `//app/src-tauri:unit_tests`, in the sandbox. The acceptance tests read their fixtures as runfiles, and run the Swift helper that Bazel built (`REVIEWMAP_SWIFT_HELPER`).
- The LLM pass (`//crates/core:llm`, and CORE-004 in `//crates/core:core_rules`) runs `scripts/fake-llm.sh` (`REVIEWMAP_FAKE_LLM`), or small wrappers around it that a test writes, in place of `claude` and `codex`. No test runs a real coding agent: the core runs an LLM only when a request carries `LlmOptions`, and every test that sets them names the fake as the command and turns off the `gh` lookup of the pull request. Replies are cached in the app's cache, keyed by the command among the rest, so each test runs a wrapper of its own, in its own temporary directory, and never reads replies another test cached; the cache's location can't be chosen.
- `//crates/core:typescript_fixtures`, TypeScript outside Bazel from start to end, on a Yarn Classic workspace made from `crates/core/tests/fixtures/ts-yarn` and the same workspace in Yarn 4 with Plug'n'Play, `crates/core/tests/fixtures/ts-berry` (`yarn_berry_workspace_index`), and a project that is Classic at base and Berry at head. Like the Bazel fixture tests it reads its fixtures from the checkout, so it runs outside the sandbox (`local`), is never cached, and inherits `PATH` and `HOME` to find Node.js; the tests that index fetch Yarn Classic and Yarn 4 (corepack) and scip-typescript (npx) on a first run, and say `skipped: …` in their log without Node.js.
- `//app:test`, the UI's Vitest tests, which read the prototype's reports in `Tests/ReviewMapCoreTests/Fixtures`.
- `//crates/core:bazel_fixtures`, the index builds from start to end. They start Bazel in nested workspaces made from fixtures that `.bazelignore` keeps out of this workspace (`crates/core/tests/fixtures`, and the prototype's `kotlin-bazel-indexed`). So the target runs outside the sandbox (`local`), one at a time (`exclusive`), is never cached (`no-cache`), reads the fixtures from the checkout, keeps the app's home in `target/reviewmap-test-home` so the nested output bases stay warm, runs the nested Bazel without `TEST_TMPDIR` so it uses the user's repository cache (in one that `bazel test` empties every run, each run downloaded the JDKs and the Kotlin compiler again), and inherits `PATH`, `HOME` and `JAVA_HOME` to find Bazel, the JDK and Xcode. A test whose tool is missing passes early and says `skipped: …` in its log (`bazel-testlogs/crates/core/bazel_fixtures/test.log`); `REVIEWMAP_SKIP_BAZEL_TESTS=1` skips them all (`--test_env=REVIEWMAP_SKIP_BAZEL_TESTS=1`).

## Benchmarking a review

Every review logs how long each of its steps took. The CLI's `--report` mode prints these lines to stderr among its progress lines, and the app writes them to its log, `<cache>/logs/app.log`. Each step ends with one line that gives its seconds and a label:

```
[timing] 62.09s cmd bazel build (swift index, head, workspace "")
```

Steps nest: a `graph` step holds its `cmd bazel cquery`, and an `index swift` step holds its `cmd bazel build`. A TypeScript index of a Bazel workspace runs two Bazel commands: `cmd bazel query (typescript index, …)`, which finds the npm links to build, and `cmd bazel build (typescript index, …)`. `scripts/bench-phases.py` puts only the build in its "TS Bazel" column, so add the query's line to it when you compare with runs from before rm-9e2v, which had no query. Kotlin's indexers also run several at a time, and so do Bazel commands of different output bases (rm-zm5r): the graph queries of every workspace and side run up to `REVIEWMAP_BAZEL_JOBS` at once (default: half the cores, at most 4, fewer when little memory is free; `crates/core/src/bazel/jobs.rs`), and a TypeScript workspace's base build starts once head's build is done, while head runs scip-typescript. Index builds of different workspaces still run one after another. `REVIEWMAP_BAZEL_JOBS=1` runs every Bazel command after the previous one, as before. So the lines don't add up to the total, and `scripts/bench-phases.py` gives each phase the wall time its lines cover together, not their sum. `scripts/bench-phases.py` reads these labels:

| Label | Step |
| --- | --- |
| `cmd <program> [<bazel command>] (<what>, …)` | One external command (`Cmd` in `crates/core/src/proc.rs`). `<what>` is its purpose: `graph`, `graph key` (`bazel --version` for the graph cache's key, once per Bazel version and process; it has no side or workspace), `swift index`, `typescript index`, `kotlin index`, `scip-typescript`, `yarn install`, `kotlin indexer`, `download`. Bazel commands add the side and the workspace (`head, workspace ""` for the root), never `--output_base` |
| `open: resolve revisions`, `read trees`, `parse both sides`, `open: workspaces` | `Session::open` |
| `workspace lock`, `materialize <side> tree` | `Session::trees`: the app-owned trees |
| `graph <side> workspace "<w>"` | One workspace's build graph at one side: the graph cache's key and lookup, then on a miss `load_graph` (its `cquery`, and its `query` when that fails). A hit logs `Build graph of <side>: cached`, and base's graph taken from head's in the same review logs `Build graph of base: same as head` (`crates/core/src/bazel/cache.rs`). The seconds are the side's own work: when base waits for head's graph, the wait is not counted |
| `index <language> <side> "<unit>"` | One language's index of one workspace or project at one side, cache hits included |
| `swift merge stores (<side>, <n> stores)`, `swift helper read (<side>)` | Inside `index swift`: copying the index stores, and the Swift helper reading them |
| `typescript resolve (<side>)` | Inside `index typescript`: turning the SCIP index into references |
| `report build (<variant>, <stage> stage)` | One report (`Session::build`) |
| `shutdown bazel servers (<n>)` | Stopping the review's Bazel servers at the end |
| `write report`, `total` | The CLI: writing the `--report` file, and the whole run from `main` |

`scripts/bench-review.sh` runs one review in a Review Map home of its own and keeps what it measured. Build the binaries the way the app bundle builds them, and copy them out of `bazel-bin`, because the next build replaces them:

```bash
bazel build --config=release //crates/cli:reviewmap //helper:reviewmap-swift-helper
mkdir -p $S/bin && cp bazel-bin/crates/cli/reviewmap bazel-bin/helper/reviewmap-swift-helper $S/bin/
scripts/bench-review.sh --bin $S/bin --home $S/homes/ui --out $S/runs/ui-cold --state cold $S/repo 6324470^ 6324470 --target //app:bundle
scripts/bench-phases.py $S/runs/ui-cold $S/runs/ui-reopen   # the table of docs/rebuild-step5-speed.md, "Results"
scripts/bench-review.sh --clean $S/homes/ui                 # stop the home's Bazel servers and delete it
```

The script `cd`s into the repository and runs `reviewmap <repo> --base B --head H --no-llm --report <out>/report.json [args…]` there with `REVIEWMAP_HOME=<home>`. It writes the following to `<out>`:

- `log.txt`: every stderr line, prefixed with the seconds since the start.
- `summary.txt`: the total time, the load average at start and end, peak RSS, the machine's swap in use at start and at its peak, and the disk use of `<home>/cache`.
- `report.json`: the report.

Its options:

- `--compare <baseline report.json>` runs `diff <(jq -S . baseline) <(jq -S . new)` and fails when the two reports differ. Two runs of the same pair give the same report, cold or warm. Any difference is therefore a real change, as long as both runs used the same clone path and the same home path: the report names the repository's root, and some warnings name log files under the home.
- `--profiles` sets `REVIEWMAP_PROFILE_DIR=<out>/profiles`. The core then copies Bazel's JSON trace profile (`<output_base>/command.profile.gz`, which every build and query rewrites) after each Bazel command except `info`, which writes none.
- `--keep-bazel` sets `REVIEWMAP_KEEP_BAZEL=1`. The CLI then leaves the home's Bazel servers running at exit, as the app does between the reviews of one session, so the next run is a *session* run. The servers idle out after 15 minutes.
- `--label` and `--state` name the run in the table.

Use a scratch directory for every home, never `~/Library/Caches/reviewmap`; the script refuses that one. Don't run `bazel test //...` while a timed run is going. A *cold* run starts with `--clean`. *Reopen* means the same home with its servers stopped. *Session* means the previous run used `--keep-bazel`.

### The step-5 scenarios

These are the scenarios of [rebuild-step5-speed.md](rebuild-step5-speed.md) ("Scenarios"). They run on a scratch clone of `rebuild`, which has every commit they name, plus three synthetic commits. The commits are made with a fixed author, committer and date, so they get the same SHAs in every clone (`c82c903` bench-helper, `49cc6d7` bench-kotlin, `e51535a` bench-kotlin2):

```bash
git clone --branch rebuild "$(git rev-parse --show-toplevel)" $S/repo && cd $S/repo
export GIT_AUTHOR_NAME=bench GIT_AUTHOR_EMAIL=bench@example.invalid GIT_AUTHOR_DATE='2026-11-17T00:00:00Z'
export GIT_COMMITTER_NAME=bench GIT_COMMITTER_EMAIL=bench@example.invalid GIT_COMMITTER_DATE='2026-11-17T00:00:00Z'
# Swift helper: an extension added to helper/Sources/reviewmap-swift-helper/Model.swift.
git switch -q --detach 046c3e7
printf '\nextension ParsedFile {\n    /// Synthetic change for benchmarks: the number of declarations.\n    var declarationCount: Int { decls.count }\n}\n' >> helper/Sources/reviewmap-swift-helper/Model.swift
git commit -q -am 'bench: a Swift helper change' && git branch -f bench-helper
# Kotlin: a function added to Store.kt, then (bench-kotlin2, on top) the same function added to Cache.kt.
git switch -q --detach 046c3e7
K=Tests/ReviewMapCoreTests/Fixtures/kotlin-bazel-indexed/head
perl -0pi -e 's/\n}\n\z/\n\n    fun has(key: String): Boolean {\n        return load(key).isNotEmpty()\n    }\n}\n/' $K/store/Store.kt
git commit -q -am 'bench: a Kotlin change' && git branch -f bench-kotlin
perl -0pi -e 's/\n}\n\z/\n\n    fun has(key: String): Boolean {\n        return load(key).isNotEmpty()\n    }\n}\n/' $K/cache/Cache.kt
git commit -q -am 'bench: a second Kotlin change' && git branch -f bench-kotlin2
git switch -q rebuild && git rev-parse bench-helper bench-kotlin bench-kotlin2
```

`$S` is a scratch directory and `B="scripts/bench-review.sh --bin $S/bin"`. Each block starts from a cleaned home, and its runs follow one another in that home:

```bash
# UI: cold, then reopen the same pair; then the next pair after a reopen, and in a session.
$B --home $S/homes/ui --out $S/runs/ui-cold --state cold $S/repo 6324470^ 6324470 --target //app:bundle
$B --home $S/homes/ui --out $S/runs/ui-reopen --state "reopen, same pair" --compare $S/runs/ui-cold/report.json $S/repo 6324470^ 6324470 --target //app:bundle
$B --home $S/homes/ui --out $S/runs/ui-next --state reopen --keep-bazel $S/repo 99f2be4^ 99f2be4 --target //app:bundle
$B --home $S/homes/ui --out $S/runs/ui-next2 --state session --keep-bazel $S/repo bff6fe0^ bff6fe0 --target //app:bundle
# Rust and Swift helper in a session: the next pairs in the UI home, servers warm.
$B --home $S/homes/ui --out $S/runs/rust-session --state session --keep-bazel $S/repo f1df7b4^ f1df7b4 --target //app:bundle
$B --home $S/homes/ui --out $S/runs/helper-session --state session --keep-bazel $S/repo 046c3e7 bench-helper --target //app:bundle
# Mixed: 46 files, the root and four nested fixture workspaces, with the root warm.
$B --home $S/homes/ui --out $S/runs/mixed-session --state "session (root warm, nested cold)" $S/repo 8cf8972 046c3e7 --target //app:bundle
# No index (the UI pair, parsing, graph queries and reports only).
$B --home $S/homes/noindex --out $S/runs/noindex --state cold $S/repo 6324470^ 6324470 --target //app:bundle --no-index
# Rust: 9 .rs files in crates/core; Swift is indexed, TypeScript is not.
$B --home $S/homes/rust --out $S/runs/rust-cold --state cold $S/repo f1df7b4^ f1df7b4 --target //app:bundle
# Swift helper (synthetic).
$B --home $S/homes/helper --out $S/runs/helper-cold --state cold $S/repo 046c3e7 bench-helper --target //app:bundle
# Kotlin (synthetic), in the nested rules_kotlin fixture workspace: no --target, it gets //....
$B --home $S/homes/kotlin --out $S/runs/kotlin-cold --state cold $S/repo 046c3e7 bench-kotlin
$B --home $S/homes/kotlin --out $S/runs/kotlin-reopen --state "reopen, same pair" --keep-bazel --compare $S/runs/kotlin-cold/report.json $S/repo 046c3e7 bench-kotlin
$B --home $S/homes/kotlin --out $S/runs/kotlin-next --state session $S/repo 046c3e7 bench-kotlin2
```

The analysis didn't record which review ran before its "Rust session", "Swift helper session" and "Mixed session" rows. They ran with the Swift index of their pair still to build and the root's servers warm, which is what running them in the UI home after the UI block gives. Compare later numbers with reruns of this list, not across the two. Before any `--state cold` run, use `scripts/bench-review.sh --clean <home>`. A cold mixed review starts 10 Bazel servers and needs a machine with memory to spare (see the report).

## What is gone

- Cargo, npm and SwiftPM as ways to build: `helper/Package.swift` and `app/package-lock.json` are removed, and the code no longer looks for `helper/.build` or Cargo's `target/` directory. The CLI finds the app, and the core finds the helper, next to themselves in Bazel's output tree.
- `tauri dev`, the app window with the UI reloading from Vite: the app always embeds the UI it was built with. Work on the UI in a browser with `bazel run //app:dev`, and rebuild the app to see it there.
