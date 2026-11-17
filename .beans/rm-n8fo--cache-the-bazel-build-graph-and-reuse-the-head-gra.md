---
# rm-n8fo
title: Cache the Bazel build graph and reuse the head graph for base
status: completed
type: task
priority: high
tags:
    - speed
created_at: 2026-11-16T21:15:57Z
updated_at: 2026-11-17T23:05:41Z
parent: rm-8hfq
blocked_by:
    - rm-l8ck
---

## What

Stop querying the same Bazel build graph again. Today `Session::refine` (`crates/core/src/session.rs`, "Step 1: the build graph") calls `crate::bazel::query::load_graph` for every workspace in scope, at head and then at base, every review. Nothing is cached: reopening the same review runs the same two queries again, and when base and head have the same build definitions the base query returns what the head query just returned.

Add a graph cache:

- **Key** (a digest, like `crate::store::digest`): a format version; the workspace path; the `Scope` (targets and kind); the Bazel arguments (`Session::bazel_args`); the Bazel version (`bazel --version` once per process, or the `.bazelversion` file of the tree plus the resolved Bazel binary path); the tree entries (path and blob id) of every file that can change the graph: `BUILD`, `BUILD.bazel`, `*.bzl`, `MODULE.bazel`, `MODULE.bazel.lock`, `WORKSPACE`, `WORKSPACE.bazel`, `*.MODULE.bazel` included files, `.bazelrc` and anything it `try-import`s or `import`s, `.bazelversion`, `.bazelignore`, and lockfiles that module extensions read (`Cargo.lock`, `Cargo.toml`, `pnpm-lock.yaml`, `package.json`, `Package.swift`, `Package.resolved`); and **the list of all paths in the workspace** (paths only, not contents), because `glob()` results depend on which files exist. Also the environment that Bazel's toolchain detection reads and the app controls: `XCODE_VERSION`/`DEVELOPER_DIR` as `tools/bazel` sets them (or the selected Xcode's path and build number). When in doubt, put it in the key: a miss costs one query (8 s cold, 1 s warm), a wrong hit gives wrong components.
- **Value**: the `WorkspaceGraph` (`crates/core/src/bazel/graph.rs`) as JSON, with the path prefix of the app-owned tree removed (`node_of` already makes `build_file` workspace-relative).
- **Where**: `<cache>/graphs/<repo key>/<digest>.json` (`crate::store::cache_root()`), like the Swift index cache.
- **Use**: before `load_graph` at a side, look up the key; on a hit, use it and log "build graph of <side>: cached". After a successful head query, compute base's key; when it equals head's, use head's graph for base without querying. Store only graphs from successful queries (`load_graph` returned `Ok`), never partial ones.

## Why

Measured on 2026-11-17 on this repository (`docs/rebuild-step5-speed.md`, B2):

- Reopening a review that was already complete (`6324470^..6324470 --target //app:bundle`, all index caches hit) took 17.9 s, of which 16.3 s was the two `cquery`s (each starts a Bazel server: 6–8 s cold, 0.7–1.7 s warm).
- From empty caches the graph step takes 16–18 s at the root workspace, before any index work starts; the report with the build graph reaches the UI only after it (17.4 s).
- Of the 7 pairs measured, 6 changed no build-definition file and 3 also added or removed no file, so their base graph equals their head graph.
- A review that touched four nested workspaces spent 92 s on 8 graph queries (`8cf8972..046c3e7`).

## Where

- `crates/core/src/session.rs`: `Session::refine` step 1 (the loop over `self.in_scope` and `[Side::Head, Side::Base]`).
- `crates/core/src/bazel/query.rs`: `load_graph`; `crates/core/src/bazel/graph.rs`: `WorkspaceGraph`, `TargetNode` (need `Serialize`/`Deserialize` if they don't have them).
- `crates/core/src/store.rs`: `cache_root`, `digest`, `repo_key`.
- The source trees are `SideSource::tree` (a `crate::git::Tree`: path → entry with `oid` and `mode`), so the key is computed from git objects, not from the file system.

## Acceptance criteria

- Reopening `6324470^..6324470 --target //app:bundle` with caches kept takes at most 4 s in total (was 17.9 s), and no Bazel query runs (the log shows "cached" for both sides).
- From empty caches, `99f2be4^..99f2be4 --target //app:bundle` (no build-definition change, no file added or removed) runs one graph query, not two.
- `6324470^..6324470` (2 files added) still queries both sides.
- A unit test changes a `BUILD.bazel`, adds a file in a package, changes `--bazel-arg`, and changes the scope, and each gives a different key; an unrelated content change of a `.swift` file gives the same key.
- Reports are identical (`diff <(jq -S . a) <(jq -S . b)` empty) to the reports made with today's code for every scenario of `docs/rebuild-step5-speed.md` ("Scenarios"), cold and on reopen.
- `bazel test //...` passes.

## Dependencies and constraints

- After rm-l8ck (phase timing and the benchmark/compare script). Before or after rm-9e2v (TypeScript build); both change `session.rs`, so merge one at a time.
- No Statute rule covers components or the graph, and no guarantee changes, so no decision is needed. A wrong cache hit would show the wrong components and edges, which is why the key errs towards more inputs.
- Note for the parallel UI epic (rm-w7ge): no UI change; the graph report just arrives sooner.

## Results (2026-11-18)

Done in a new module, `crates/core/src/bazel/cache.rs` (`graph_key`, `environment`, `affects_graph`, `GraphCache`). `Session::refine` step 1 (`crates/core/src/session.rs`) computes each side's key inside the existing `graph <side> workspace "<w>"` timer. It then looks the key up in the graphs queried earlier in the same review, then in the cache, and calls `load_graph_checked` (`crates/core/src/bazel/query.rs`) only on a miss. `load_graph` keeps its signature and calls `load_graph_checked`.

### Key inputs (final)

A SHA-256 (`crate::store::digest`) of:

1. The format `graph-cache-v1`.
2. The query's fixed shape: `query::query_shape()`, which holds the flags and `--proto:output_rule_attrs`.
3. A digest of the source text of `bazel/query.rs` and `bazel/graph.rs` (`include_str!`), so a change to how a graph is made never reuses an old one.
4. The workspace path, the `Scope` (kind and targets) and `Session::bazel_args`. Each list is prefixed with its length.
5. The environment (`cache::environment`), computed for each side in the app-owned workspace directory:
   - `bazel --version` run there. Bazelisk resolves `.bazelversion` from that directory. The answer is kept per process for the same canonical Bazel binary (path and mtime) and the same `.bazelversion`, `.bazeliskrc` and `tools/bazel` blobs.
   - The Xcode that `tools/bazel` would set: a caller's `XCODE_VERSION`, otherwise `DEVELOPER_DIR` or `xcode-select -p`, plus a digest of the selected Xcode's `version.plist`. Computed once per process.
   - The PATH tools get (`tools::child_path()`).
   - The environment variables `BAZEL*`, `USE_BAZEL*`, `DEVELOPER_DIR`, `XCODE_VERSION`, `JAVA_HOME`, `HOME`, `CC`, `CXX`, `SDKROOT`, `ANDROID_HOME`, `ANDROID_SDK_ROOT` and `ANDROID_NDK_HOME`.
   - The contents of `/etc/bazel.bazelrc` and `~/.bazelrc`, which Bazel reads because nothing passes `--nohome_rc`.
   - Absolute-path files that the workspace's `.bazelrc` imports at any depth.

   When `bazel --version` fails, there is no key: the graph is queried and not stored.
6. Tree entries (path, mode, blob id), matched by file name across the whole repository, not only the workspace, because a workspace can reach outside it with `local_path_override`:
   - names: `WORKSPACE`, `.bazelversion`, `.bazelignore`, `.bazeliskrc`, `Cargo.lock`, `Cargo.toml`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `package.json`, `package-lock.json`, `yarn.lock`, `.npmrc`, `Package.swift`, `Package.resolved`, `go.mod`, `go.sum`, `go.work`;
   - patterns: any name starting with `BUILD`; ending in `.bazel`, `.bzl`, `.lock`, `.patch` or `_install.json`; containing `bazelrc`; `requirements*.txt`;
   - `tools/bazel`.
7. Every path and mode in the workspace (the whole repository for the root), for `glob()`.

### Behaviour

- **Storing.** A graph is stored only when it is complete: the query the scope asks for exited 0. That is `cquery` for explicit or xcodeproj scopes, and `query //...` for scope `all`. This is stricter than "`load_graph` returned `Ok`". A `--keep_going` query that exits non-zero but prints partial output, and the unconfigured fallback after a failed `cquery`, both still return `Ok` and are still used for the report. They are not stored, so a transient failure is never frozen into later reviews.
- **No tree paths in stored graphs.** A graph whose JSON names the repository's app-owned directory (`<cache>/bazel/<repo>`) is neither stored nor reused for base. On this repository none did.
- **Writing.** A temporary file, then a rename.
- **Location and size.** `<cache>/graphs/<repo key>/<key>.json`. A graph of `//app:bundle` is about 1.1 MB.
- **Log lines.**
  - A hit logs "Build graph of <side>[ of <w>]: cached".
  - When base's key equals the key of the graph head just queried, base logs "Build graph of base: same as head" and runs no query.
  - `bazel --version` has its own timing line, `cmd bazel (graph key)`: 0.04–0.3 s, once per process.
- **Docs.** `docs/rebuild-build.md` (the label table) and `docs/rebuild-step5-speed.md` (B2) are updated.

### Measurements

Measured with `scripts/bench-review.sh` on a scratch clone of `rebuild` at 757e51e with the three synthetic commits, using scratch homes. "Old" is the release binary built from 757e51e. Other sessions were using the machine, with a 1-minute load average of 8–14.

| Run | old | new |
| --- | --- | --- |
| Reopen `6324470^..6324470 --target //app:bundle`, total | 13.6 s (graph: head 6.8 + base 5.8) | **0.57 s** (graph: head 0.04 + base 0.00, both "cached", no query) |
| Cold `99f2be4^..99f2be4 --target //app:bundle`, graph step | 15.3 s (2 cquerys: 8.1 + 7.2) | **7.2 s** (1 cquery; base "same as head") |
| Same run, report with the build graph at | 16.0 s | **7.8 s** |
| Same run, total | 96.1 s | 86.0 s |
| Cold `6324470^..6324470`, graph step | 14.5 s (2 cquerys) | 16.2 s (2 cquerys: 2 files added) |
| Reopen of `99f2be4`, `bff6fe0`, `f1df7b4`, `046c3e7..bench-helper` | not measured as reopens. In the old chain these pairs took 20.8 s (reopen, graph 12.4 s), 9.0 s, 6.1 s and 6.9 s (session, graph 1.8–2.3 s) | 0.47–0.56 s (graph 0.0 s) |
| Mixed `8cf8972..046c3e7` (5 workspaces, 10 graphs) | session with the root warm: 124.8 s, graph 93.8 s | same session 118.1 s (8 queries, root cached); reopen **0.71 s** |
| No index, cold, then reopen | 15.0 s | 15.1 s, then 0.25 s |
| Kotlin `bench-kotlin` | cold 60.3 s | cold 58.3 s (1 query, base "same as head"). Reopen 8.5 s: graph 0.2 s; the Kotlin aspect builds remain (B7) |

The two cold UI totals, 89.8 s old and 105.6 s new, differ in the Swift build: 56.9 s against 67.6 s, under load 13–14. The graph step was 14.5 s against 16.2 s, with the same two cquerys.

### Acceptance criteria

- **Reopen at most 4 s, no query, "cached" for both sides:** 0.57 s. The log shows "Build graph of head: cached", "Build graph of base: cached", and no `cquery` or `query`.
- **Cold `99f2be4^..99f2be4` runs one graph query:** one `cquery`, then "Build graph of base: same as head".
- **`6324470^..6324470` still queries both sides:** the cold run ran two `cquery`s.
- **Key unit test** (`bazel::cache::tests::the_key_changes_with_every_input_of_the_graph`):
  - each of these changes the key: a changed `BUILD.bazel`, a file added in a package, a file removed, a `--bazel-arg`, other scope targets, another scope kind, another environment, another workspace, a changed `.bazelrc`;
  - these keep it: an unrelated `.swift` content change, a `README` change.

  Further tests cover nested workspaces, the file patterns, and following `.bazelrc` imports.
- **Reports identical for every scenario, cold and on reopen:** 37 runs. Every new-binary report is identical (`jq -S`) to the old binary's for the same pair and home, through `--compare`. The scenarios: UI `6324470` cold and reopen; `99f2be4` and `bff6fe0` in the UI chain, from cold, and on reopen; Rust `f1df7b4` in a session, cold and on reopen; Swift helper `bench-helper` the same; Mixed `8cf8972..046c3e7` in a session with the root warm, and on reopen; no index cold and on reopen; Kotlin `bench-kotlin` cold and on reopen, `bench-kotlin2` in a session and on reopen. Mixed was not run from empty caches: it starts 10 Bazel servers on a 16 GB machine shared with other sessions.
- **`bazel test //...` passes:** 9 of 9. `//crates/core:bazel_fixtures` took 162 s once, because `~/.bazelrc` had just changed (below) and every kept fixture output base restarted its server. A rerun with `--nocache_test_results` took 37.7 s.

### Seen while measuring

At 09:45, while the suite ran, something else on the machine (another session or the user) rewrote `~/.bazelrc`; it now sets `startup --max_idle_secs=600` and `--host_jvm_args=-Xmx2g`. The key holds that file's content, so the next reopen (`new-ui-reopen`, 14.4 s) missed and queried both sides. Every run after it hit. This was a correct miss. A startup-only option can't change a graph, but the key doesn't parse bazelrc files, which keeps it on the safe side.

In a session, a cache hit means a side's Bazel server isn't started. A later miss at that side then pays the server start: `new-rust-session` spent 7.0 s on base's `cquery`, against 0.7 s in the old chain, where every review had kept base's server warm. The cost moves to a later review; it isn't added.

### Follow-ups (not done here)

- **Eviction.** `store::evict` doesn't trim `<cache>/graphs`. Every distinct key adds about 1 MB on this repository, so the cache grows with every reviewed pair that changes the path list. Give it a share of the cache limit, as `index` and `syntax` have.
- **Concurrency (rm-zm5r).** Head's graph comes first so that base can reuse it. Running both sides' queries at once would lose that reuse unless base waits for head's key.
