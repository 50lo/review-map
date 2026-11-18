---
# rm-9e2v
title: 'TypeScript index: build only the npm links and generated sources that scip-typescript reads'
status: completed
type: task
priority: high
tags:
    - speed
created_at: 2026-11-16T21:15:56Z
updated_at: 2026-11-17T20:32:01Z
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

## Results (2026-11-18)

Done in `crates/core/src/index/typescript.rs` (`build`, `Setup::Bazel`; `input_query`, `IndexInputs`, `build_targets`). `FORMAT` is `typescript-index-2`; the cache key still holds the scope targets, because the query's result is not known when the cache is checked. `session.rs` is unchanged.

### What it runs

Before the build, in the same workspace and output base: `bazel query --notool_deps --output=label_kind` with

```
let d = deps(set(<scope>)) in
let s = labels("srcs", kind("ts_project|js_library", $d)) in
kind("npm_link_package_store", $d)
  + filter("\.(ts|tsx|mts|cts)$", kind("generated file", rdeps(siblings($s), $s except kind("ts_project", $s), 1)))
```

Then `bazel build` (with `--disk_cache`, `--keep_going` and the workspace's Bazel arguments, as before) of the in-workspace labels it found (labels starting with `@` are dropped: nothing of theirs is laid out in the workspace's bazel-bin). Where it differs from the proposal above, and why:

- **Generated files.** `kind("generated file", deps(...))` finds only generated files that some rule names by their own label. The ts-bazel fixture names its generated `src/generated/version.ts` through the genrule (`srcs = [":version"]`), so that form misses it. The query instead takes the generated `.ts`/`.tsx`/`.mts`/`.cts`/`.d.ts` outputs of whatever a `ts_project` or `js_library` in the scope names in `srcs`. It leaves out the outputs of `ts_project` itself (the `.js`/`.d.ts` it compiles from in-repo sources), which are not inputs; including them would compile all the TypeScript again. On the fixture it finds exactly `//packages/app:src/generated/version.ts`; on this repository, none.
- **No workspace Bazel arguments on the query.** They are build options, which `bazel query` may reject; the graph's plain `query` (`load_graph`) leaves them out for the same reason. The build still gets them.
- **`--notool_deps`.** What only the exec configuration builds lands in another bin directory, not bazel-bin, so the old full build never laid it out where the indexer looks either. On this repository the result is the same with and without it (14 links).
- **No `--keep_going` on the query, and fallback on any failure.** A partial answer could miss a link and drop the packages it lays out, so a failed query (non-zero exit) builds the scope targets as before. So does a query that finds no npm link (generated files alone lay out no `node_modules`). Both say so in the log.
- **A plain query, not cquery.** `select()` branches count whichever way they go, so it can only build more links than the configured build would, never fewer.

The log (progress lines, so stderr for the CLI and `app.log` for the app) gets "Finding what the TypeScript index of <side> <sha> needs Bazel to build", then either "<side> <sha>: Bazel builds 14 npm links for the TypeScript index: //app:node_modules/…" (with "and N generated TypeScript files …" when there are some) or "<side> <sha>: The query for what the TypeScript index needs failed (log: …) / found no npm links, so Bazel builds the scope targets for the TypeScript index: …", then the unchanged "Building <side> <sha> with Bazel for the TypeScript index". The per-build log file `typescript-<side>-<sha>.log` gets the query, any error, and the same line. The query's timing line is `cmd bazel query (typescript index, <side>, workspace "")`; `scripts/bench-phases.py` puts only the build in its "TS Bazel" column (noted in `docs/rebuild-build.md`), so the numbers below add the two.

### Targets selected on this repository

For `6324470^..6324470` with `--target //app:bundle`, with scope `//...`, and for `99f2be4` and `bff6fe0`, at head and base alike: the 14 `npm_link_package_store` targets of `//app:node_modules`, one per entry of `app/package.json` (`@tauri-apps/api`, `@tauri-apps/plugin-dialog`, `@types/node`, `@types/react`, `@types/react-dom`, `@vitejs/plugin-react`, `@xyflow/react`, `elkjs`, `react`, `react-dom`, `shiki`, `typescript`, `vite`, `vitest`), and no generated files. The "15" above counted the `js_library` `//app:node_modules` too; it is 14 links. No run fell back.

### Generated TypeScript at its source path (not solved)

A generated TypeScript file lands under bazel-bin, not at its source path, and scip-typescript reads the tree, so it still does not see the file. The old full build had the same limit. The ts-bazel fixture has one: `packages/app/src/build_info.ts` imports `./generated/version`, which only `//packages/app:version` (a genrule) makes. It stays syntax-only at both sides with its `index-partial` warning, as before (`typescript_index_through_bazel`: TypeScript 5 files, 4 indexed). Making such files visible (for example by linking them into the tree for the indexer, as `node_modules` is) would change coverage, so it needs its own task; this repository has no such file. The query finds and builds them, and the log names them and says the indexer does not see them.

### Measurements

Mac mini M1, 16 GB, `scripts/bench-review.sh` on a scratch clone of `rebuild` 8e1a3f3, scratch `REVIEWMAP_HOME`s. "Old" is the release binary built from 8e1a3f3; "new" is this change. Old and new used the same clone path and home path, and each new run's report was compared with `--compare` against the old run of the same pair. Cold runs started from `--clean` homes; the new chain is the documented UI chain (cold, reopen, `99f2be4` with `--keep-bazel`, then `bff6fe0` in that session). TS query + build is the `cmd bazel query (typescript index …)` plus `cmd bazel build (typescript index …)` lines of one side.

| Run | TS query + build, head | TS query + build, base | TS Bazel column (`bench-phases.py`, build only, both sides) | scip-ts | total | report vs old |
| --- | --- | --- | --- | --- | --- | --- |
| old, cold `6324470^..6324470 --target //app:bundle` | – + 202.9 s | – + 21.1 s | 224.0 | 11.3 | **315.2 s** | (baseline) |
| new, cold, same pair | 0.70 + 3.87 = **4.6 s** | 0.61 + 2.40 = **3.0 s** | 6.3 | 7.1 | **91.4 s** | identical |
| new, reopen, same pair | cached | cached | – | – | 12.7 s | identical |
| new, `99f2be4` after reopen | 0.67 + 0.91 = 1.6 s | cached | 0.9 | 3.7 | 21.5 s | – |
| old, session `bff6fe0` (after the old cold run, so base was not cached) | – + 12.3 s | – + 14.0 s | 26.4 | 28.1 | 62.1 s | (baseline) |
| new, session `bff6fe0` | 0.24 + 0.53 = **0.8 s** | cached | 0.5 | 3.4 | **8.4 s** | identical |
| old, cold `6324470^..6324470`, scope `//...` | – | – | 306.5 | 92.8 | 411.1 s | (baseline) |
| new, cold, scope `//...` | 1.51 + 4.22 = 5.7 s | 1.52 + 2.91 = 4.4 s | 7.1 | 6.6 | **24.6 s** | identical |

- Acceptance: cold head 4.6 s (≤ 15), base 3.0 s (≤ 5), total 91.4 s (≤ 130); session `bff6fe0` 0.8 s (≤ 3, was 14.3 s in `docs/rebuild-step5-speed.md`); scope `//...` built only the 14 links.
- Reports: TypeScript 51/51 files indexed for 6324470 in both scopes; the same `index-partial`, `checks-held-back` and other warnings and the same edges, since `diff <(jq -S . old) <(jq -S . new)` is empty for all three pairs (and for the reopen).
- The old runs are noisier than the new ones: the machine's load average reached 15–20 during the old cold UI and session runs (other sessions), and the old `//...` run overlapped with a `bazel test` of mine. So the old `//...` row (306.5 s build, 92.8 s scip-ts) is high; the earlier measurement of that build was 215 s (rm-kmap). The new runs ran at load 4–11 with nothing of mine alongside.
- Tests: `//crates/core:unit_tests` (new: `index_inputs_from_the_query`, `the_build_is_the_npm_links_the_scope_needs`, `without_npm_links_the_build_falls_back_to_the_scope`), and `//crates/core:bazel_fixtures` `typescript_index_through_bazel`, which now also asserts that each side builds exactly `//:node_modules/@types/semver //:node_modules/typescript //packages/app:node_modules/@demo/lib //packages/app:src/generated/version.ts`, not `//...`.
- `bazel test //...` in the worktree: all 9 test targets pass, `//crates/core:bazel_fixtures` (278.7 s) and `//crates/core:typescript_fixtures` (Yarn path, unchanged) among them.
