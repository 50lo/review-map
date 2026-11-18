# Review Map

A macOS app for code review that shows a change as structure (components, dependency edges, changed contracts, findings) instead of line diffs. It reviews Swift and Kotlin in Bazel workspaces, and TypeScript in Yarn workspaces (Classic and Berry) and in Bazel workspaces that use rules_ts with rules_js. The app is Tauri 2 with a React UI over a Rust core; a small SwiftSyntax helper parses Swift. The plan is in [docs/rebuild-phase1-proposal.md](docs/rebuild-phase1-proposal.md).

## Requirements

- macOS 14 or later.
- [Bazelisk](https://github.com/bazelbuild/bazelisk), installed as `bazel` (`brew install bazelisk`). Bazelisk is required: it runs the Bazel version pinned in `.bazelversion` (9.3.1) and the workspace's `tools/bazel` wrapper, which makes Bazel detect Xcode again after an Xcode update. A plain Bazel binary skips that wrapper.
- Full Xcode, selected with `xcode-select`. Command Line Tools alone aren't enough: Bazel needs Xcode for Swift, and the app reads Swift indexes with Xcode's `libIndexStore`.
- git.

Bazel fetches Rust, Node.js, and every Rust and npm package itself. You don't need Cargo, Node.js, or npm to build Review Map.

The projects you review need their own tools for index mode (see [Languages](#languages)): Bazel and Xcode for Swift, Bazel and a JDK 17 or newer for Kotlin, and Node.js for TypeScript.

## Build and install

```sh
git clone https://github.com/50lo/review-map.git
cd review-map
scripts/build-app.sh --install
```

`scripts/build-app.sh --install` builds an optimized `Review Map.app` (`bazel build --config=release //app:bundle`), copies it to `~/Applications`, and links `~/.local/bin/reviewmap` to the command inside it. `PREFIX=/some/dir` puts the link in `/some/dir/bin` instead. If that directory isn't on your `PATH`, the script says so. Run it again after pulling to update.

Without `--install`, the script only builds the app and prints where it is in Bazel's output tree.

## Use it

```sh
cd /path/to/repo
reviewmap
```

`reviewmap` opens the app, or focuses it if it's already running, and starts a review of the branch checked out in the current directory against `main`. The app shows the structural review as soon as it has one, then refines it with compiler indexes. Progress is shown, and you can cancel.

| Option | Meaning |
| --- | --- |
| `[repo]` | The repository, or any directory inside it (default: the current directory). |
| `--base <ref>` | Base ref: a branch, tag, or sha (default: `main`). |
| `--head <ref>` | Head ref (default: the branch checked out in the repository). |
| `--no-merge-base` | Compare against the base itself instead of the merge-base of base and head. |
| `--target <label>` | A Bazel target that defines the review scope; repeat for several (default: `index.targets` in `reviewmap.yml`, else the `top_level_targets` of the repo's rules_xcodeproj rule). |
| `--bazel-arg <arg>` | An extra argument for Bazel queries and builds, such as `--config=sim`; repeat for several. |
| `--no-index` | Don't build indexes: only links that syntax proves are shown. |
| `--llm <tool>` | Run the [LLM pass](#llm-pass) with `claude` or `codex` (default: the app's settings, where it is off). |
| `--llm-command <path>` | Run this executable in place of the LLM tool, such as `scripts/fake-llm.sh`. |
| `--llm-model <name>` | The model the LLM tool uses. |
| `--no-llm` | Don't run the LLM pass, whatever the settings say. |
| `-h`, `--help` | Show help. |
| `-V`, `--version` | Show the version. |

Review Map reads committed content only, never the working tree. It builds both sides of the change in its own copies outside your repository, so nothing is written to the repository you review.

## Languages

| Language | Projects | Syntax | Index mode |
| --- | --- | --- | --- |
| Swift | Bazel (rules_swift) | SwiftSyntax, in the bundled helper | Bazel builds the scope targets with indexing on; the app reads the index store with Xcode's `libIndexStore`. |
| Kotlin | Bazel (rules_kotlin) | tree-sitter | Bazel builds the targets' compile classpath; the Kotlin indexer from the scip-java launcher indexes each target. The launcher is downloaded once; `REVIEWMAP_SCIP_JAVA` names another. Needs a JDK 17 or newer. |
| TypeScript, TSX | Yarn projects and workspaces, Classic (1.x) and Berry (2 and later); Bazel with rules_ts and rules_js | tree-sitter | scip-typescript 0.4.0, run through `npx`. Yarn Classic projects get `yarn install` with scripts off; Yarn Berry projects get `yarn install` with the project's own Yarn release, scripts off, and the `node-modules` linker whatever `.yarnrc.yml` sets (scip-typescript cannot resolve through Plug'n'Play); Bazel workspaces get no install: Bazel builds only the npm links the review's targets depend on, which lays out `node_modules` itself. Needs Node.js. |

Index mode is on by default. Without an index for a language or a file, Review Map shows only the links that syntax alone proves, never links matched by name, and says so with an `index-unavailable` or `index-partial` warning. Checks that need complete references, such as finding unused declarations, are held back until the index is there (`checks-held-back`).

Every install runs in the app's own copy of the revision, never in the reviewed repository. For a Yarn Berry project, index mode runs the Yarn release the project commits (`yarnPath` in `.yarnrc.yml`) and the Yarn plugins it configures, as a Bazel build runs the workspace's own rules; without a committed release it runs the `packageManager` version through corepack (or npx on Node.js 25 and later), and without a `packageManager` pin either, Yarn 4.18.1 for a lockfile in a Yarn 4 format and Yarn 3.8.7 for an older one. pnpm, npm and Bun projects outside Bazel are detected and reported as not indexed. Go, Rust, Gradle, SwiftPM, and direct Xcode builds are outside phase 1. Java and Objective-C files in the review scope are reported as coverage gaps.

## LLM pass

Review Map can ask a coding-agent CLI, `claude` or `codex`, to annotate a review: a risk for every changed region, which context regions to keep and in what order, a one-line summary of each component and review item, and a structural review of the whole change (findings of kind intent, placement, missing, duplicate, and complexity). The pass runs after the analysis is complete, on the final report; the review is usable while it runs, and cancelling it keeps the review as it was. A reply that fails validation, or a call that fails, is dropped and the deterministic scores and findings stay, with an `llm-rejected` warning. Accepted replies are cached, so the same change reviewed again makes no calls.

The pass is off by default, because each call costs money. Turn it on for every review in the app's `settings.json` (in `~/Library/Application Support/reviewmap`):

```json
{ "llm": { "tool": "claude", "model": "sonnet" } }
```

or for one review with `reviewmap --llm claude` (or `--llm codex`, with `--llm-model <name>`). `--no-llm` turns it off for one review whatever the settings say. The CLI must be signed in already; Review Map runs it with the prompt on stdin, in an empty temporary directory, with no tools. If the repository has a `REVIEW.md` at the head commit, both prompts include it.

To try the pass without a model, use the stand-in that the tests use: `reviewmap --llm-command scripts/fake-llm.sh` (with `--llm codex` to imitate codex). `FAKE_LLM_MODE` makes it reply with prose around the JSON (`prose`), out-of-range values (`invalid`), a failing exit (`fail`), or claude's error result (`error`).

## reviewmap.yml

An optional `reviewmap.yml` at the root of the reviewed repository, read from the head commit:

```yaml
components:
  - name: Checkout
    paths: ["App/Features/Checkout/**"]
    layer: domain
layers:               # top to bottom: a component may use its own layer and the ones below it
  - name: app
    components: ["App", "App/*"]
split: { threshold: 30, maxDepth: 3 }
exclude: ["**/Pods/**"]
generated: ["**/*.generated.swift"]
index:
  enabled: true
  targets: ["//ios:App"]        # the Bazel targets that define the review scope
  bazelArgs: ["--config=sim"]   # extra arguments for Bazel queries and builds
```

## Where data lives

- Notes, reviewed marks, and settings: `~/Library/Application Support/reviewmap`.
- Analysis and index caches, which are safe to delete: `~/Library/Caches/reviewmap`.
- `REVIEWMAP_HOME` moves both under one directory (`data` and `cache`).

The Open button opens a file in your editor: `REVIEWMAP_EDITOR`, else the editor chosen in the app's settings, else Xcode.

## Development

```sh
bazel build //...                                   # everything
bazel test //...                                    # Rust tests, the UI's Vitest tests, the fixture tests
scripts/build-app.sh                                # Review Map.app, optimized; prints where it is
REVIEWMAP_REPORT=<report.json> bazel run //app:dev  # the UI in a browser, reloading on changes
bazel run @rules_rust//tools/rust_analyzer:gen_rust_project  # rust-project.json for rust-analyzer
```

No test runs a real coding agent: the LLM tests use `scripts/fake-llm.sh`. Some fixture tests start Bazel, Node.js, or a JDK from your `PATH`. A test whose tool is missing passes early and says `skipped: …` in its log. `--test_env=REVIEWMAP_SKIP_BAZEL_TESTS=1` skips the tests that start nested Bazel workspaces.

[docs/rebuild-build.md](docs/rebuild-build.md) describes the build: how the Rust, Swift, and UI parts fit together, how to add a Rust or npm package, what each test target covers, and how Xcode updates are handled.

| Part | Where |
| --- | --- |
| Core: Git access, analysis, Bazel queries, indexing | `crates/core` |
| The `reviewmap` command | `crates/cli` |
| App (Tauri 2) | `app/src-tauri` |
| UI (React, React Flow, ELK, Shiki) | `app/src` |
| Swift helper (SwiftSyntax, IndexStoreDB) | `helper/` |
| Product rules and decisions | `statute/` |
| Work items | `.beans/` |
