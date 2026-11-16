---
# rm-9e2v
title: 'TypeScript index: build only the npm links and generated sources that scip-typescript reads'
status: todo
type: task
priority: high
tags:
    - speed
created_at: 2026-11-16T21:15:56Z
updated_at: 2026-11-16T21:15:56Z
parent: rm-8hfq
blocked_by:
    - rm-l8ck
---

## What

For a Bazel workspace that builds TypeScript with rules_ts and aspect_rules_js, the TypeScript index step builds the review's scope targets in full before running scip-typescript. Make it build only what scip-typescript reads: the npm link targets that rules_js lays out as `bazel-bin/<package>/node_modules`, and any generated TypeScript sources the scope depends on.

Today (`crates/core/src/index/typescript.rs`, `build`, branch `Setup::Bazel`): `bazel build --disk_cache=… --experimental_convenience_symlinks=ignore --keep_going <bazel args> -- <targets>`, where `<targets>` are the scope targets of the workspace (`Session::index_typescript` in `crates/core/src/session.rs` passes the explicit/xcodeproj scope, or `//...` when the scope is "all"). Then `bazel info bazel-bin`, then `link_node_modules` gives each package directory of the workspace a `node_modules` of symlinks: first-party packages to their source directory in the app-owned tree, everything else to `bazel-bin/<package>/node_modules/<name>`. scip-typescript then reads the sources and those `node_modules`. It never reads the outputs of `ts_project`, Vite, Rust, Swift or the app bundle.

Proposed: before the build, find the targets to build with one query in the same output base and with the same Bazel arguments, and build those instead of the scope targets:

- `kind("npm_link_package_store", deps(set(<scope targets>)))`: the `node_modules/<name>` links of each package (for this repo: the 15 links of `//app:node_modules`, which pull in 385 `npm_package_store_internal` targets);
- plus generated TypeScript inputs: files in `deps(set(<scope>))` that are outputs of a rule (not source files), inside the workspace, ending in `.ts`, `.tsx`, `.mts`, `.cts` or `.d.ts` (for example `kind("generated file", deps(...))` filtered by extension). If a generated file needs to be visible to scip-typescript at its source path, say so in the bean before solving it; this repository has none, so it may only need to be detected and reported.
- If the query fails or returns nothing, fall back to today's build of the scope targets, and say so in the log.

Keep everything after the build as it is: `bazel info bazel-bin`, `link_node_modules`, the scip-typescript command, `resolve`, the cache key (`cache_key` must change, by bumping `FORMAT` from `typescript-index-1` to `typescript-index-2`, because what is built changed).

## Why

Measured on 2026-11-17 on this repository (`docs/rebuild-step5-speed.md`, B1), reviewing a UI-only change (`6324470^..6324470`, `--target //app:bundle`):

- From empty caches, the TypeScript step's Bazel build took 205 s at head (2292 actions, 1463 executed: the Rust app and CLI, swift-syntax again, Vite, the bundle) and 20.5 s at base: 226 s of the review's 324 s.
- In a warm session, the next UI review (`bff6fe0^..bff6fe0`) spent 14.3 s of 24.6 s there: Vite's `//app:dist` 7.7 s, recompiling the Rust app 4.6 s.
- Building only `//app:node_modules` in the same cold head tree took 7.6 s (457 actions, critical path 0.8 s) and laid out the same package set. scip-typescript over it produced a SCIP index byte-identical (same SHA-1) to the one over the full bundle build.

Without `--target` and without `index.targets` in `reviewmap.yml` the scope is `//...`, which builds everything in the repository (215 s cold at head in an earlier measurement recorded for bean rm-kmap).

## Where

- `crates/core/src/index/typescript.rs`: `build` (the `Setup::Bazel` arm), `FORMAT`, maybe a new `fn index_inputs(env, targets, cancel) -> Result<Vec<String>>`.
- `crates/core/src/session.rs`: `Session::index_typescript` passes `targets` (unchanged contract: `Setup::Bazel { env: &BazelEnv, targets: &[String] }`).
- Tests: `crates/core/tests/bazel_fixtures.rs` (`typescript_index_through_bazel`, fixture `crates/core/tests/fixtures/ts-bazel`), `crates/core/tests/typescript_fixtures.rs` (Yarn path, must be unaffected).

## Acceptance criteria

- On this repository, with the benchmark script of rm-l8ck (phase timing and the benchmark script) and an empty scratch `REVIEWMAP_HOME`:
  - `6324470^..6324470 --target //app:bundle`: the TypeScript Bazel step takes at most 15 s at head and 5 s at base (was 205 s and 20.5 s); the whole review at most 130 s (was 324 s).
  - `bff6fe0^..bff6fe0 --target //app:bundle` in a warm session: the TypeScript Bazel step takes at most 3 s (was 14.3 s).
  - The same pair without `--target` (scope `//...`) also builds only the link targets.
- The final report of each of those runs is identical (`diff <(jq -S . a) <(jq -S . b)` empty) to the report made with today's code: TypeScript `indexedFiles`/`files` (51/51 for 6324470), the same `index-partial` and `checks-held-back` warnings, the same edges.
- `//crates/core:bazel_fixtures` (TypeScript through Bazel) and `//crates/core:typescript_fixtures` pass; the ts-bazel fixture's report is unchanged.
- The log names which targets were built, and says when it fell back to the scope targets.

## Dependencies and constraints

- Do rm-l8ck (phase timing and the benchmark script) first (timing and the benchmark/compare script), so this task can show its numbers and its unchanged report.
- CORE-003 (`statute/rules/core.md`): building less can only make imports unresolvable, never create links; a file whose in-repo import comes out as an unresolved local is already dropped to syntax-only with an `index-partial` warning. So the risk is coverage, and the acceptance criteria check coverage is unchanged. No Statute decision is needed as long as coverage is unchanged.
- CORE-002: nothing may be written into the reviewed repository; all of this happens in the app-owned tree.
- Changes `session.rs` only if the target list must be passed differently; other tasks of the epic also change `Session::refine`, so merge one at a time. No `app/src` changes.
