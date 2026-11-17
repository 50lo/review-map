---
# rm-l8ck
title: Log the time of each review phase and add a review benchmark script
status: completed
type: task
priority: high
tags:
    - speed
created_at: 2026-11-16T21:15:49Z
updated_at: 2026-11-17T10:58:32Z
parent: rm-8hfq
---

## What

Make the time each review phase takes visible in Review Map's own logs, and add a script that benchmarks a review and checks that its report did not change. Today the progress events (`Event::Progress` in `crates/core/src/session.rs`) say what is happening but not how long it took, and nothing records the time of Bazel commands, index reads or report builds.

1. **Phase timing in the core.** Log the duration of each step, always (not only behind an environment variable), through the same channel the app and CLI already log to:
   - every external command run through `Cmd` in `crates/core/src/proc.rs` (`output`, `output_lenient`, `run_logged`): program name and the Bazel subcommand (`cquery`, `query`, `build`, `info`), without `--output_base`;
   - `Session::open`: reading the two trees and `parse_sides`;
   - `Session::trees`: `Workspaces::materialize` per side;
   - `Session::refine`: `load_graph` per workspace and side; `index_workspaces`' `build` call per language, workspace and side;
   - `index::swift::load`: `merge_store` and `SwiftHelper::index`;
   - `index::typescript::load`: `resolve`;
   - `Session::build`: each report build, with its variant and stage.
   The CLI's `--report` mode prints them to stderr; the app writes them where it writes its progress log today. Keep the format machine-readable, e.g. `[timing] 62.09s cmd bazel build (swift index, head, workspace "")`.
2. **A benchmark script**, `scripts/bench-review.sh` (bash), that runs `reviewmap <repo> --base B --head H --no-llm --report <out>/report.json [extra args]` with `REVIEWMAP_HOME` set to a directory given on the command line, timestamps every stderr line, writes `<out>/log.txt`, `<out>/summary.txt` (total time, load average at start and end, peak RSS of the processes whose command line contains the home directory, `du` of `<home>/cache/*` and `<home>/cache/bazel/*`) and, when `REVIEWMAP_PROFILE_DIR`-style collection is asked for, a copy of Bazel's `<output_base>/command.profile.gz` after every Bazel command (Bazel rewrites that file on every command). A `--clean` option stops the Bazel servers of the home (`bazel --output_base=<ob> shutdown` for each `<home>/cache/bazel/<repo>/<side>/out/*`), runs `chmod -R u+w`, and deletes it.
   And `scripts/bench-phases.py` that turns one or more `log.txt` files into a markdown table with the columns used in `docs/rebuild-step5-speed.md` ("Results"): parse, graph, Swift build, Swift read, TS Bazel, scip-ts, Kotlin Bazel, Kotlin indexer, download, reports, graph report at, total.
3. **Report comparison.** The script's `--compare <baseline report.json>` option runs `diff <(jq -S . baseline) <(jq -S . new)` and fails when they differ. Two runs of the same pair give byte-identical reports after `jq -S` today (checked on 2026-11-17 between a cold run and a reopen), so any difference is a real change.
4. Document the script in `docs/rebuild-build.md` (one short section) and list the scenarios of `docs/rebuild-step5-speed.md` ("Scenarios") with their exact commands, including how the two synthetic commits were made (an extension added to `helper/Sources/reviewmap-swift-helper/Model.swift`; a function added to `Tests/ReviewMapCoreTests/Fixtures/kotlin-bazel-indexed/head/store/Store.kt` and then to `cache/Cache.kt`), so later tasks of this epic can rerun them in a scratch clone.

## Why

Every other task in the epic rm-8hfq (rm-9e2v, rm-n8fo, rm-zm5r, rm-e2b4, rm-2tan, rm-gnyb, rm-0ixm) must show two things: the time it saved, per phase, and that the final report is unchanged (CORE-003: same coverage and links). The step-5 analysis on 2026-11-17 did this with throwaway instrumentation that was not committed; this task makes it permanent so the numbers are comparable from task to task. It also helps the user: a slow review today says "Building head … with Bazel for the TypeScript index" for minutes, and the log can't tell afterwards which step was slow.

## Where

- `crates/core/src/proc.rs` (`Cmd`), `crates/core/src/session.rs` (`Session::open`, `trees`, `refine`, `index_workspaces`, `build`), `crates/core/src/index/swift.rs` (`load`), `crates/core/src/index/typescript.rs` (`load`).
- `crates/cli/src/main.rs` (`write_report` prints progress to stderr already).
- New: `scripts/bench-review.sh`, `scripts/bench-phases.py`. Docs: `docs/rebuild-build.md`.

## Acceptance criteria

- A `--report` run on this repository prints one timing line per step listed above; the sum of the step lines accounts for at least 95% of the run's wall time.
- `scripts/bench-review.sh` reproduces the "UI, reopen, same pair" row of `docs/rebuild-step5-speed.md` (`6324470^..6324470 --target //app:bundle`, run twice in the same scratch home) within ±25%: about 18 s, of which about 16 s is graph queries.
- `--compare` passes for two runs of the same pair and fails when one run uses `--no-index`.
- No change to any report: the reports of the step-5 scenarios are identical with and without this task's code.
- `bazel test //...` passes.

## Dependencies and constraints

- None before it; the other tasks of the epic depend on it.
- Logging must not slow anything measurably (it is a handful of lines per review).
- Doesn't touch `app/src` (the UI epic rm-w7ge works there in parallel). If the app's log location needs to change, do that in `app/src-tauri` only.


## Summary of changes (2026-11-17)

- **Timing lines, always on.** `crates/core/src/proc.rs` has `set_timing_log`, `timing` and `timer` (an RAII guard that logs on drop). Without a sink the lines are dropped, as in tests and in the CLI's launch mode. `Cmd::output`, `output_lenient` and `run_logged` log `cmd <program> [<bazel command>] (<what>, <side>, workspace "<w>")`, and never `--output_base`. `Cmd::what`/`context` set the purpose, and `BazelEnv::command` adds the side and workspace. Timed steps: `Session::open` (resolve, read trees, parse, workspaces); `Session::trees` (lock, materialize per side); `Session::refine` (`graph <side> workspace "<w>"`, `index <language> <side> "<unit>"`); `index::swift::load` (merge stores, helper read); `index::typescript::load` (resolve); `Session::build` (`report build (<variant>, <stage> stage)`); `shutdown_all`. The CLI's `--report` mode prints them to stderr and adds `write report` and `total`. The app writes them to `<cache>/logs/app.log` (one line in `app/src-tauri/src/lib.rs`). The label list is in `docs/rebuild-build.md`, "Benchmarking a review".
- **Benchmark aids in the product:** `REVIEWMAP_PROFILE_DIR` (core: copy Bazel's `command.profile.gz` after each Bazel command) and `REVIEWMAP_KEEP_BAZEL` (CLI: skip `shutdown_all`, for *session* runs).
- **Scripts.** `scripts/bench-review.sh` takes `--home`, `--out`, `--bin`, `--compare`, `--profiles`, `--keep-bazel`, `--label`, `--state` and `--clean`. It refuses `~/Library/Caches/reviewmap`. `scripts/bench-phases.py` prints the "Results" table and, per run, the share of wall time that the timing lines cover (the union of their intervals).
- **Docs.** `docs/rebuild-build.md` "Benchmarking a review" lists every step-5 scenario with exact commands. The three synthetic commits are made with a fixed author, committer and date, so they get the same SHAs in any clone: bench-helper `c82c903`, bench-kotlin `49cc6d7`, bench-kotlin2 `e51535a`.

## Results

Measured on the Mac mini (M1, 16 GB), from a scratch clone of `rebuild` a99ebec with release binaries and scratch homes. Other sessions were using the machine (1-min load 5–13).

| Run | state | parse | graph | Swift build | Swift read | TS Bazel | scip-ts | Kotlin Bazel | Kotlin indexer | download | reports | graph report at | **total** | load |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| No index | reopen | 0.0 | 12.4 | – | – | – | – | – | – | – | 0.2 | 12.5 | **13.0** | 13→12 |
| UI | cold | 0.4 | 14.8 | 62.9 | 0.8 | 219.6 | 9.7 | – | – | – | 0.4 | 15.4 | **310.7** | 7→13 |
| UI | reopen, same pair | 0.0 | 13.1 | – | – | – | – | – | – | – | 0.3 | 13.2 | **13.9** | 12→12 |
| UI (again) | reopen, same pair | 0.0 | 12.8 | – | – | – | – | – | – | – | 0.3 | 12.9 | **13.8** | 12→13 |
| UI next (99f2be4) | reopen | 0.2 | 13.2 | 2.5 | 0.4 | 15.1 | 5.2 | – | – | – | 0.3 | 13.5 | **37.6** | 7→7 |
| UI next (bff6fe0) | session | 0.2 | 2.0 | 1.2 | 0.4 | 11.8 | 4.3 | – | – | – | 0.3 | 2.4 | **20.8** | 7→7 |
| Rust | cold | 0.3 | 15.9 | 66.2 | 0.9 | – | – | – | – | – | 0.4 | 16.5 | **84.8** | 9→8 |
| Rust | session | 0.2 | 1.8 | 2.9 | 0.8 | – | – | – | – | – | 0.3 | 2.1 | **6.4** | 7→7 |
| Swift helper | cold | 0.4 | 16.2 | 60.4 | 0.8 | – | – | – | – | – | 0.3 | 16.9 | **79.1** | 10→6 |
| Swift helper | session | 0.2 | 1.8 | 3.1 | 0.8 | – | – | – | – | – | 0.3 | 2.1 | **6.5** | 7→7 |
| Kotlin | cold | 0.3 | 33.5 | – | – | – | – | 23.9 | 7.6 | 59.7 | 0.3 | 34.1 | **126.0** | 7→5 |
| Kotlin | reopen, same pair | 0.0 | 3.5 | – | – | – | – | 5.0 | 0.3 | – | 0.3 | 3.7 | **9.1** | 5→5 |
| Kotlin next (bench-kotlin2) | session | 0.0 | 0.2 | – | – | – | – | 3.4 | 2.8 | – | 0.3 | 0.4 | **7.3** | 5→5 |
| Mixed | session (root warm, nested cold) | 0.0 | 181.5 | – | – | 49.0 | 19.3 | – | – | – | 0.3 | 181.7 | **252.3** | 6→5 |

Acceptance criteria:

- **Coverage.** In every run, the timing lines cover 99.1–100% of wall time.
- **UI reopen, same pair.** 13.9 s (13.8 s on a second reopen), of which graph queries take 13.1 s. The analysis measured 17.9 s and 16.3 s; this run is 22% lower, within ±25%. The baseline a99ebec binary took 15.6 s in the same home, so the logging doesn't slow anything measurably.
- **`--compare`.** It passes for every pair run twice (cold against reopen for UI and Kotlin). It fails against a `--no-index` run of the UI pair: 1780 diff lines, starting with `indexedFiles` and `resolution`.
- **Reports unchanged.** Every scenario's report from this task's binary is identical, after `jq -S`, to the report of the a99ebec binary run in the same home: UI, UI next ×2, Rust, Swift helper, Kotlin, Kotlin next, Mixed (warm root) and No index. The a99ebec runs came after the new ones, so they read the index caches that the new binary built. Cold equals warm was checked separately, by UI cold against two reopens and Kotlin cold against reopen.
- **Two numbers differ from the analysis, for reasons outside the code.** Kotlin cold's scip-java download took 59.7 s against 15.9 s (the network). Mixed session's graph took 181 s against 94 s: the nested fixture workspaces resolve Bzlmod from the network on every fresh output base (B3 and rm-0ixm in `docs/rebuild-step5-speed.md`).
