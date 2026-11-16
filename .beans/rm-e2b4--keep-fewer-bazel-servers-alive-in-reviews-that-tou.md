---
# rm-e2b4
title: Keep fewer Bazel servers alive in reviews that touch several workspaces
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

Keep fewer Bazel servers alive during a review. Today every `(workspace, side)` pair gets its own output base and therefore its own Bazel server (`BazelEnv::new` in `crates/core/src/bazel/workspace.rs` registers it in `OUTPUT_BASES`), started with `--max_idle_secs=900`, and all of them stay up until the app quits (`shutdown_all`). A review that touches N workspaces keeps 2·N Java servers in memory for the rest of the session, even after their last command.

Change:

1. When a review no longer needs a workspace's servers (after its last graph query and index build in `Session::refine`), shut down the servers of nested workspaces (`bazel --output_base=<ob> shutdown`, as `shutdown_all` does) and remove them from `OUTPUT_BASES`. Keep the root workspace's servers (and the primary workspace's), which the next review in the session most likely needs: warm servers answer a graph query in 0.7–1.7 s instead of 6–8 s.
2. Start Bazel servers of nested workspaces with a smaller heap if Bazel allows it per command line (`--host_jvm_args=-Xmx…` is a startup option; measure whether it helps or slows the queries before keeping it).
3. Measure whether nested workspaces need two servers at all: base and head of a nested workspace are queried and built one after the other; a single output base per workspace, used for head then base, would halve servers and disk, but loses Bazel's in-memory state between sides and conflicts with running sides in parallel (rm-zm5r (concurrent Bazel work)). Write down the measured result in this bean; implement only if it is a clear gain.

## Why

Measured on 2026-11-17 on this repository (`docs/rebuild-step5-speed.md`, B3), on a Mac mini with 16 GB:

- `8cf8972..046c3e7 --target //app:bundle` touches the root and four nested fixture workspaces; the review ended with 10 Bazel servers alive, at least 3.4 GB resident (the sampler misses workers).
- From empty caches the same review ran with the system at 4.7 GB of swap and a 5-minute load average of 106; its Swift index build took 353 s, against 62 s for the same build in a review with only the root workspace (same 68 actions). A repeat run under similar swap (4.6 GB) took 64 s for the Swift build but 571 s in total. Other work was running on the machine during both runs, so how much of the pressure the review's own servers caused is not known; measure it in this task (peak swap and server count with and without the change, on an otherwise idle machine if possible).
- Each nested workspace's server is used for one `query //...` per side and, for ts-bazel, one TypeScript build of 3–4 s; then it sits idle for up to 15 minutes, or until the app quits.

## Where

- `crates/core/src/bazel/workspace.rs`: `OUTPUT_BASES`, `BazelEnv::new`, `BazelEnv::command`, `shutdown_all`; a new `shutdown(output_base)`.
- `crates/core/src/session.rs`: `Session::refine` (knows when a workspace's last job is done).

## Acceptance criteria

- After `8cf8972..046c3e7 --target //app:bundle` completes in a session, at most 2 Review Map Bazel servers are alive (`pgrep -f "output_base=<REVIEWMAP_HOME>"`), the root's.
- During that review, the peak number of Review Map Bazel servers alive at once is at most the concurrency bound of rm-zm5r (concurrent Bazel work) plus 2.
- A second review of a UI change in the same session still finds the root servers warm (graph queries under 2 s each, as in the "session" rows of `docs/rebuild-step5-speed.md`).
- Reports unchanged (`diff <(jq -S . a) <(jq -S . b)` empty) for the scenarios of `docs/rebuild-step5-speed.md`.
- `bazel test //...` passes; `//crates/core:bazel_fixtures` keeps the app's home in `target/reviewmap-test-home` and must not slow down by more than 10%.

## Dependencies and constraints

- After rm-l8ck (phase timing and the benchmark script). Works with or without rm-zm5r (concurrent Bazel work); if both are done, do this one second.
- No Statute decision. No `app/src` change; `app/src-tauri/src/lib.rs` still calls `shutdown_all` on quit.
