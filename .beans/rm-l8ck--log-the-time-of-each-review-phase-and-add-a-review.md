---
# rm-l8ck
title: Log the time of each review phase and add a review benchmark script
status: todo
type: task
priority: high
tags:
    - speed
created_at: 2026-11-16T21:15:49Z
updated_at: 2026-11-16T21:15:49Z
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
