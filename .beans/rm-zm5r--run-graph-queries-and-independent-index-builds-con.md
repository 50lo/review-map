---
# rm-zm5r
title: Run graph queries and independent index builds concurrently, with a bound
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

Run Bazel work that doesn't depend on each other at the same time, with a bound, instead of strictly one command after another.

Today `Session::refine` (`crates/core/src/session.rs`) runs, in order: for each workspace in scope, `load_graph` at head then at base; then for each language (Swift, Kotlin, then TypeScript), `index_workspaces`, which for each workspace builds head then base. Each (workspace, side) pair has its own app-owned tree and its own output base (`Workspaces::workspace_dir`, `Workspaces::output_base` in `crates/core/src/bazel/workspace.rs`), so its Bazel server is independent of the others. A Bazel server runs one command at a time, so commands in the same output base must stay in order, but commands in different output bases can overlap.

Make these concurrent:

1. **Graph queries**: all `(workspace, side)` queries of step 1 at once, bounded (see below). The graph report is emitted once all have returned, as today.
2. **Index builds of different output bases**: within one language, base's build can run while head's runs (they are separate servers; base mostly hits the shared `--disk_cache` after head, so start head first and base when head's Bazel build finishes, or both at once and measure which is faster). Different nested workspaces can run at once.
3. Keep the order between languages within the same output base (Swift build → TypeScript build), since they share a server.

Bound: a small worker count, default `min(4, cores / 2)`, and lower when memory is short. Each cold Bazel server took 0.3–0.7 GB in the measurements, and a review that kept 10 servers alive pushed a 16 GB machine into 4.7 GB of swap. Make it configurable with an environment variable (`REVIEWMAP_BAZEL_JOBS`), as `REVIEWMAP_KOTLIN_JOBS` is for the Kotlin indexer (`index_jobs` in `crates/core/src/index/kotlin.rs`).

Progress: `Event::Progress` messages already name the side and workspace; with concurrency, several are in flight. Keep each message self-contained (side and workspace in it). The UI shows the latest message only; that is acceptable for this task (no UI change).

Cancelling must still stop everything: `Cancel` registers each child process (`crate::proc::Cancel::register`), so concurrent commands are covered, but check that `Session::refine` returns the cancellation error and not a different one.

## Why

Measured on 2026-11-17 on this repository (`docs/rebuild-step5-speed.md`, B2 and B3):

- From empty caches, the root workspace's two graph `cquery`s run one after another: 8.4 + 8.4 s before the graph report appears (17.4 s). In parallel, about 9 s.
- `8cf8972..046c3e7` touches the root and four nested fixture workspaces (`crates/core/tests/fixtures/{swift-bazel,ts-bazel}/{base,head}`): 8 nested graph queries took 10–13 s each, one after another, 92 s in total with the root warm. With a bound of 4, about 25–30 s.
- Index builds: the cold Swift base build took 5.0 s and the TypeScript base build 20.5 s, after their head builds; these partly overlap with head work when run concurrently.

## Where

- `crates/core/src/session.rs`: `Session::refine` step 1 and `Session::index_workspaces` (its `build` closure is `FnMut`; it must become `Fn + Sync` or the work must be restructured into jobs per output base). `rayon` is already a dependency; a scoped thread pool with the bound is enough.
- `crates/core/src/index/swift.rs`: `load` takes `&mut SwiftHelper`; the helper reads one request at a time, so either start one helper per concurrent job or keep reading the stores in order after concurrent builds.
- `crates/core/src/proc.rs`: `Cancel`.

## Acceptance criteria

- From empty caches, `6324470^..6324470 --target //app:bundle`: the graph report arrives within 11 s (was 17.4 s).
- With the root warm and the nested workspaces cold, `8cf8972..046c3e7 --target //app:bundle`: graph step at most 35 s (was 92 s), and the peak resident memory of Bazel servers stays at or below today's (3.4 GB measured) with the default bound.
- Reports identical (`diff <(jq -S . a) <(jq -S . b)` empty) to today's for every scenario of `docs/rebuild-step5-speed.md`.
- Cancelling during the graph step and during index builds stops all running Bazel commands within 2 s and leaves the report final with "indexing was cancelled" notes, as today (CORE-003 boundary: a cancelled language ends syntax-only).
- `bazel test //...` passes.

## Dependencies and constraints

- After rm-l8ck (phase timing and the benchmark script). Best after rm-9e2v (TypeScript build) and rm-n8fo (graph cache), which remove most of the work being parallelised; all three change `Session::refine`, so do them one at a time.
- The app-owned trees are only changed between jobs under the repository's lock (`Workspaces::acquire`); concurrency must stay inside one review, after `Session::trees` has materialised both trees.
- No Statute decision: the commands and their results are the same. No `app/src` change.
