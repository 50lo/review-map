---
# rm-2tan
title: Use the same Bazel configuration flags in every command of an output base
status: todo
type: task
priority: normal
tags:
    - speed
created_at: 2026-11-16T21:15:57Z
updated_at: 2026-11-16T21:15:57Z
parent: rm-8hfq
blocked_by:
    - rm-l8ck
---

## What

Use the same configuration-changing Bazel flags for every command in an app-owned output base, so Bazel keeps its analysis cache between the graph query and the index builds.

Today, in the same output base (one per workspace and side, `Workspaces::output_base` in `crates/core/src/bazel/workspace.rs`):

1. `load_graph` (`crates/core/src/bazel/query.rs`) runs `cquery … <bazel args> deps(set(<scope>))` with no `--features`.
2. The Swift index build (`crates/core/src/index/swift.rs`, `load`) runs `build --features=swift.index_while_building --features=swift.use_global_index_store --remote_download_regex=… --aspects=… <bazel args>`.
3. The TypeScript build (`crates/core/src/index/typescript.rs`, `build`) runs `build --disk_cache=… <bazel args>` with no `--features`.
4. The Kotlin build (`crates/core/src/index/kotlin.rs`, `load`) runs `build --aspects=… <bazel args>` with no `--features`.

`--features` is part of the build configuration, so each switch prints "Build option --features has changed, discarding analysis cache" and re-analyses the whole graph. It also gives the Swift compile actions different keys in the index build and in the TypeScript build, so a TypeScript build that reaches Swift targets compiles them again.

Change: pass the same set of configuration flags (at least both `--features=swift.*` flags) to every `cquery`, `build` and `info` in an output base whose workspace has Swift, or put them in a generated `--bazelrc`/`common` section of the app's aspect package (`.reviewmap_aspects`, written by `write_aspects` into the app-owned tree, never into the reviewed repository). Non-configuration flags (`--aspects`, `--output_groups`, `--build_event_json_file`, `--keep_going`, `--disk_cache`, `--remote_download_regex`) don't discard the analysis cache and can stay per command; check this with the build logs.

## Why

Measured on 2026-11-17 on this repository (`docs/rebuild-step5-speed.md`, B4): every one of the builds in every scenario logged "discarding analysis cache". With a warm server the re-analysis cost about 1 s per command for `//app:bundle` (the Swift index build in a warm session completed in 1.2 s, almost all of it analysis); from a cold server the analysis phase of `//app:bundle` was 5.2 s of the 8.4 s `cquery`. In the cold UI review the TypeScript build at head compiled swift-syntax a second time (0 disk-cache hits for the Swift actions) because its configuration differed from the index build's. That second cost mostly goes away with rm-9e2v (TypeScript: build only what scip-typescript reads), which stops building the app bundle; the analysis-cache cost stays.

## Where

- `crates/core/src/bazel/query.rs` (`load_graph`), `crates/core/src/index/swift.rs` (`load`), `crates/core/src/index/typescript.rs` (`build`), `crates/core/src/index/kotlin.rs` (`load`), `crates/core/src/bazel/workspace.rs` (`BazelEnv::command`, `BazelEnv::info`).

## Acceptance criteria

- No Review Map build log of the step-5 scenarios contains "discarding analysis cache" except on the first command of a server.
- In a warm session, `bff6fe0^..bff6fe0 --target //app:bundle`: the Swift index build and the TypeScript build each finish at least 0.5 s faster than before (measure with the benchmark script of rm-l8ck, three runs each).
- The graph is the same: the configured graph report and the final report are identical (`diff <(jq -S . a) <(jq -S . b)` empty) for every scenario of `docs/rebuild-step5-speed.md`. Configuration checksums inside `TargetNode::configs` may change value but not count.
- `bazel test //...` passes, including `//crates/core:bazel_fixtures` for Swift, Kotlin and TypeScript.

## Dependencies and constraints

- After rm-l8ck (phase timing and the benchmark script). Independent of the others but touches the same files as rm-9e2v (`typescript.rs`); merge after it.
- The Swift cache key (`swift.rs`, `load`) includes `job.env.args`; if the flags go into `env.args`, Swift and TypeScript cache keys change once. That is fine, but keep user-given `--bazel-arg`s separate from the app's own flags in the key.
- No Statute decision. No `app/src` change.
