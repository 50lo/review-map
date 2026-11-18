---
# rm-zm5r
title: Run graph queries and independent index builds concurrently, with a bound
status: completed
type: task
priority: normal
tags:
    - speed
created_at: 2026-11-16T21:15:57Z
updated_at: 2026-11-18T02:18:01Z
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



## Results (2026-11-18)

### What changed

The code is in `crates/core/src/session.rs` (`Session::refine` step 1 and `Session::index_workspaces`), `crates/core/src/bazel/jobs.rs` (new) and `crates/core/src/proc.rs`.

- **The bound.** `bazel::jobs::jobs()` returns `REVIEWMAP_BAZEL_JOBS` when it is set (at least 1). Otherwise it is `min(4, cores / 2)`, capped at `(free memory − 2 GiB) / 1 GiB` and never below 1.
  - Free memory is `hw.memsize × kern.memorystatus_level / 100` on macOS and `MemAvailable` on Linux.
  - On this Mac mini (8 cores, 16 GB) the bound is 4. The memory cap starts to lower it only when less than about 6 GB is free.
  - 1 GiB per job is about the measured RSS of the largest server, the root workspace's (0.83–0.96 GB). Each nested fixture server took 0.24–0.28 GB.
  - `REVIEWMAP_BAZEL_JOBS=1` restores the old strictly sequential order, including the TypeScript overlap below.
- **Graph step.**
  - For each workspace, both sides' cache keys are computed first.
  - When the keys are equal, head is queried first, and base takes head's graph ("same as head"), as rm-n8fo requires.
  - When the keys differ (or there is no key), head and base are queried at the same time.
  - Workspaces run on a pool of `jobs()` threads.
  - The results are applied in the old order (workspace by workspace, head then base), so the reports, warnings and `workspaceInfos` don't depend on which query finished first.
  - The `graph <side> workspace` timing line is the side's own work (key, lookup, query) and never includes the wait for head.
- **Index step.**
  - Units are still indexed one after another, head before base, and languages keep their order (Swift, Kotlin, TypeScript), so commands in one output base stay in order.
  - The only overlap is in a rules_ts unit: base starts as soon as head's `bazel build` returns, while head runs scip-typescript. The hook is `TypeScriptIndexJob::bazel_done`, behind a latch that also opens when head fails.
  - Running both TypeScript sides at once from the start was measured and was no faster: each build took 6.3 s together against 3.8 + 2.5 s one after the other, because base lost head's disk-cache hits.
  - Indexing different workspaces at once was implemented and measured too: it saved about 5 s on the mixed review but raised the peak memory of the Bazel servers. It was removed.
- **Shared tools.**
  - The Swift helper is shared behind a mutex.
  - Yarn installs and scip-typescript run one at a time (`index::typescript::NODE_TOOLS`): npx and Yarn Classic caches are not safe for concurrent installs, and each scip-typescript takes about 0.8 GB.
  - TypeScript's temporary SCIP file now names its unit.
- **A hang found and fixed (`proc::spawn`).**
  - In one of about twelve concurrent mixed runs, the review hung forever after its graph queries.
  - A thread was blocked reading a finished child's stdout. `lsof` showed the pipe's write end held by a Bazel server (`java`) of another workspace.
  - Cause: macOS has no `pipe2`, so the standard library creates a child's pipes and marks them close-on-exec a moment later. A Bazel client that another thread started in between inherited the pipe and passed it to the server it daemonised.
  - Every child the core starts now goes through `proc::spawn`, which holds one lock while the child starts (not while it runs). This covers `Cmd`, the Swift helper, the LLM CLI, `xcrun`, `xcode-select`, `java -version` and `bazel shutdown`.
  - No hang after the fix, in the 20 runs of the final binary (the 14-run chain, 3 mixed, 3 UI cold) or in the test runs.
- **Cancelling.**
  - `Cancel::register` now stops a child that registers after `cancel()` took its list. With several commands in flight, one can start in that moment.
  - A cancelled query or build returns `Cancelled`. The first one in result order ends `refine` with it, as before.
- **Benchmarks and docs.**
  - `scripts/bench-phases.py` gives each phase the wall time its timing lines cover together (an interval union). Logs of sequential runs give the same numbers as before.
  - `scripts/bench-review.sh` records swap in use at start and at peak.
  - `docs/rebuild-build.md` and `docs/rebuild-step5-speed.md` (B2, B3) are updated.

### Measurements

Measured with `scripts/bench-review.sh` on a scratch clone of `rebuild` at b7f9d92 with the three synthetic commits, in scratch homes.

- "Bean" is this bean's numbers, from 046c3e7, before rm-9e2v and rm-n8fo.
- "Today" is the release binary of b7f9d92, re-measured first.
- "New" is this branch's release binary.
- Other sessions were using the machine: the 1-minute load ranged from 4 to 17.
- Memory columns are the peak RSS of every process whose command line names the home (as `bench-review.sh` reports it). "Servers only" counts just the Bazel server JVMs, sampled every 0.5 s.

| Scenario, measure | Bean | Today (b7f9d92) | New |
| --- | --- | --- | --- |
| UI cold `6324470^..6324470 --target //app:bundle`: graph report at | 17.4 s | 15.4–16.9 s (4 runs) | **12.9–14.2 s** (7 runs); 12.9 and 13.4 s in the two runs started at load < 4, against 15.4 s for today's binary at the same load |
| … graph step (two `cquery`s) | 16.8 s | 14.9–15.6 s | 12.3–13.0 s |
| … Swift index step | 67 s | 57.8–59.3 s | 57.4–60.1 s (unchanged: one workspace) |
| … TypeScript index step (wall) | 236 s (pre-rm-9e2v) | 15.0–16.8 s | **14.1–14.2 s** (base overlaps head's scip-typescript) |
| … total | 323.7 s | 89.6–92.5 s | 85.1–90.7 s |
| … peak RSS, processes naming the home | 2.4 GB | 4.55–4.70 GB | 4.40–4.60 GB |
| Mixed `8cf8972..046c3e7`, root warm, nested cold: graph step | 92–93.8 s | 95.8, 107.6, 118.5 s; 111.5–121.7 s with the new binary at `REVIEWMAP_BAZEL_JOBS=1` | **27.5–35.0 s in 9 of 13 runs**; 38.0, 41.7 and 51.8 s when the machine was busy, 56.5 s when the registry was slow (below). The final binary: 27.5, 30.9, 31.1, 56.5 s |
| … index steps (total − graph report) | 65 s (pre-rm-9e2v) | 28–35 s | 25–39 s (unchanged within noise: units still run one after another) |
| … total | 159.6 s | 124.0–153.6 s | 53.0–70.0 s (89.1 s in the 56.5 s run) |
| … peak RSS, Bazel servers only | – | 4.14–4.35 GB (mean 4.27; 4 runs: today's binary once, the new binary at `REVIEWMAP_BAZEL_JOBS=1` three times) | **3.90–4.43 GB (mean 4.19; 5 runs of the final index design)** |
| … peak RSS, processes naming the home | 3.4 GB | 4.40–4.82 GB (8 runs) | 3.93–5.08 GB (6 runs of the final index design) |
| … swap in use | 4.7 GB (busy machine) | 220–252 MB, no growth | 220–252 MB, no growth |
| No index, cold: graph report at | 8.5 s | 14.3 s | 12.7–13.0 s |
| Rust cold `f1df7b4`: graph report at / total | – | 15.7 / 74.8 s | 12.7–12.9 / 70.8–71.5 s |
| Swift helper cold (base "same as head"): total | – | 72.1 s | 73.5–75.1 s (one query, nothing to overlap) |
| Kotlin cold `bench-kotlin`: total | 72.1 s | 64.3 s | 65.2 s; another run took 118.1 s because downloading scip-java took 58 s against 11 s (network) |
| Session and reopen pairs (`99f2be4`, `bff6fe0`, Rust, helper, Kotlin) | – | 0.5–13.2 s | the same within 0.7 s |

Notes on the numbers:

- **Today's peak memory is higher than the bean's 3.4 GB.** In every run of either binary, 10 Bazel servers are alive at the end. The root servers are bigger since rm-n8fo, and `~/.bazelrc` changed on 2026-11-18. So "today" is the baseline, not 3.4 GB.
- **The 56.5 s mixed run.** Only the three ts-bazel fixture queries were slow: about 39 s each, all at the same moment, against about 14 s in the other runs. These queries resolve Bzlmod modules from the Bazel Central Registry, so this was the network. The Swift fixture queries in the same run took their usual 11–14 s. rm-l8ck saw the same kind of swing (Mixed graph 94 against 181 s).
- **Graph times depend on load.** The mixed review's 8 nested queries, 4 at a time, are two rounds of about 14 s each, so the step's floor is about 28–30 s. Any slowdown of the queries takes it past 35 s. In the 38.0, 41.7 and 51.8 s runs, every query was slower, the Swift fixtures' too (13–25 s each instead of 11–15 s): other work on the machine. A 14th run hung before the spawn fix (above) and is not counted. Two cold `cquery`s of the root take about 7.5 s each one after the other, and about 12.5 s each when they run together, because they compete for the CPU (8 cores, shared with other sessions).

### Acceptance criteria

- **UI cold: graph report within 11 s (was 17.4 s). Not met: 12.9–14.2 s.** Today's binary gives 15.4–16.9 s on the same code. The two `cquery`s do run at once, but each cold analysis of `//app:bundle` uses several cores, so together they take about 12.5 s instead of about 7.5 s alone. In the two runs started at a 1-minute load below 4, the graph report came at 12.9 and 13.4 s, against 15.4 s for today's binary. What remains is CPU, which more concurrency can't remove. rm-2tan (the same flags in every command) and rm-0ixm don't touch this either. Reaching 11 s would take a smaller analysis per server or one server for both sides (item 12 of `docs/rebuild-step5-speed.md`).
- **Mixed, root warm and nested cold: graph step at most 35 s (was 92 s). Met under normal load; exceeded in 4 of 13 runs.** With the default bound, 9 of 13 runs took 27.5–35.0 s, and today's binary took 95.8–118.5 s. Three runs took 38.0, 41.7 and 51.8 s while other work slowed every query. One took 56.5 s while the Bazel Central Registry was slow (above); network time is item 8 (rm-0ixm). The margin is thin: two rounds of about 14 s.
- **Peak Bazel server memory at or below today's with the default bound. Met on the servers' own memory:** 3.90–4.43 GB (mean 4.19 GB, 5 runs) against 4.14–4.35 GB (mean 4.27 GB, 4 runs) today. With workspaces indexed at once, before the change back, it was 4.16–4.57 GB (mean 4.35 GB, 4 runs).
  - Each server's own peak is the same, and so is the number of servers (10).
  - Counting every process that names the home (Bazel clients and workers too), the spread is 3.93–5.08 GB against 4.40–4.82 GB today. One run reached 5.08 GB.
  - Swap stayed at 220–252 MB with no growth in every run.
  - Indexing workspaces at once was removed to keep this criterion (see above).
- **Reports identical. Met.** Every report of this branch equals today's after `jq -S`, through `--compare`: 59 comparisons, 0 differences.
  - Three full chains of the step-5 scenarios, 14 runs each: the first build, the build with the TypeScript overlap, and the final binary.
  - 13 more mixed runs (the default bound, `REVIEWMAP_BAZEL_JOBS=1`, and units one at a time) and 4 more UI cold runs.
  - The scenarios: UI `6324470` cold and reopen; `99f2be4` reopen; `bff6fe0`, Rust and Swift helper in a session; Mixed in a session and on reopen; no index; Rust, Swift helper and Kotlin cold; Kotlin reopen and next.
- **Cancelling stops every Bazel command within 2 s and ends with the "indexing was cancelled" notes. Met.** New test `bazel_fixtures::cancelling_stops_every_bazel_command_and_ends_syntax_only`, on the ts-bazel fixture with the graph and index caches removed:
  - It cancels 300 ms after the graph query starts, and again 300 ms after the TypeScript build starts.
  - The review ends 0.05 s and 0.07–0.10 s later.
  - The graph cancel ends with no graph-stage report, so the query really was interrupted. The index cancel ends before scip-typescript started.
  - The final report is complete, with TypeScript syntax-only and an `index-unavailable` warning ending "indexing was cancelled" (CORE-003).
  - A `bazel info` in each output base afterwards runs without "Another command is running", so no server is still busy.
- **`bazel test //...` passes:** 9 of 9, uncached. `//crates/core:bazel_fixtures` takes 41 s.

### Follow-ups (not done here)

- **Fewer Bazel servers (rm-e2b4).** Peak memory is set by the number of servers a review keeps alive (10 in the mixed review), not by concurrency.
- **The 11 s target for a cold graph report.** Concurrency can't reach it on this machine (above).
