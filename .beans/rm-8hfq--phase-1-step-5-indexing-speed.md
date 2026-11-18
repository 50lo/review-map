---
# rm-8hfq
title: 'Phase 1 step 5: indexing speed'
status: todo
type: epic
priority: high
tags:
    - speed
created_at: 2026-11-16T21:15:33Z
updated_at: 2026-11-16T21:15:33Z
---

Step 5 of the phase 1 rebuild plan (`docs/rebuild-phase1-proposal.md`, "Implementation and validation order"): make indexing and analysis faster where measurements show the time goes, while keeping reference results and coverage exactly as they are (CORE-003 in `statute/rules/core.md`).

On 2026-11-17 the user decided to start step 5 before the manual comparisons of step 3, driven by measurements an agent takes on this repository rather than by manual timings. Step 3's correctness comparisons still happen later, so every task here must keep the final change report identical to its baseline.

## Why

Indexing is slow even on this repository, which is small. Measured on `rebuild` 046c3e7 (Mac mini M1, 16 GB, full method and numbers in `docs/rebuild-step5-speed.md`):

- A UI-only change reviewed with `--target //app:bundle` takes 324 s from empty caches. 226 s of that is the TypeScript step's Bazel build of the whole app bundle, although scip-typescript only needs the `node_modules` that rules_js lays out (7.6 s to build alone, with a byte-identical index).
- Reopening the same review takes 17.9 s, 16.3 s of which is querying the Bazel build graph again at both sides (nothing caches it).
- The next UI review in the same app session takes 24.6 s, 14.3 s of which is again the TypeScript step's bundle build (Vite 7.7 s, Rust app 4.6 s).
- A change that touches four nested Bazel workspaces starts 10 Bazel servers one after another (92 s of graph queries with the root warm) and, from empty caches, took 571–883 s on a 16 GB machine with 4.6–4.7 GB of swap in use (other work was running too, so the share caused by the review's own servers is unknown).
- The Rust core itself is fast: parsing 0.2–0.8 s, each report build 0.06–0.1 s.

## Tasks, in order

The report's prioritised list has 12 items; these tasks are the top ones. The order matters because most of them change `Session::refine` in `crates/core/src/session.rs`:

1. rm-l8ck: keep phase timings in the log and add a benchmark script (needed by every other task to show its gain and its unchanged report).
2. rm-9e2v: TypeScript index: build only what scip-typescript reads.
3. rm-n8fo: cache the build graph and reuse the head graph for base when they must be equal.
4. rm-zm5r: run graph queries and independent index work concurrently, with a bound.
5. rm-e2b4: keep fewer Bazel servers alive in reviews that touch several workspaces.
6. rm-2tan: use the same Bazel configuration flags for every command in an output base.
7. rm-gnyb: skip indexing languages that have no changed file. The user chose this on 2026-11-17; a CORE-003 Statute decision must be proposed and approved before the code is merged.
8. rm-0ixm: remove first-run network costs (Bzlmod resolution of nested workspaces, scip-java download).

Items 9–12 of the report (keeping Bazel servers after the app quits, Kotlin result caching and Bazel-action indexing, reusing Swift index stores from the user's own builds, one output base per workspace for both sides) are not tasks yet; see the report.

## Constraints for every task

- CORE-001..006 (`statute/rules/core.md`) stay as they are. In particular CORE-003: the main report never matches references by name; coverage for unused-api, orphaned, conformers and untested is judged over every file of a language in the repository; a file the index misses is syntax-only and listed in `index-partial`. A change that would alter any of that needs a proposed Statute decision first (`statute decide`), approved by the user.
- CORE-002: nothing is written into the reviewed repository. App-owned trees and caches under `REVIEWMAP_HOME` (or `~/Library/Caches/reviewmap`) are fine.
- Measure with `REVIEWMAP_HOME` pointing at a scratch directory so the user's caches are untouched.
- Build and test with Bazelisk as `docs/rebuild-build.md` says (`bazel test //...`); the Bazel fixture tests (`//crates/core:bazel_fixtures`, `//crates/core:typescript_fixtures`) must keep passing.
- These tasks change only `crates/core` and `crates/cli`. The UI epic rm-w7ge works in `app/src` at the same time; don't touch `app/src` here.
