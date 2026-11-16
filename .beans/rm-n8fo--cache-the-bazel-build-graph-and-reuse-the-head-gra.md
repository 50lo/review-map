---
# rm-n8fo
title: Cache the Bazel build graph and reuse the head graph for base
status: todo
type: task
priority: high
tags:
    - speed
created_at: 2026-11-16T21:15:57Z
updated_at: 2026-11-16T21:15:57Z
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
