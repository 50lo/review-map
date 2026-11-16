---
# rm-0ixm
title: 'Remove first-run network costs: nested workspace lockfiles and the scip-java download'
status: todo
type: task
priority: low
tags:
    - speed
created_at: 2026-11-16T21:15:57Z
updated_at: 2026-11-16T21:15:57Z
parent: rm-8hfq
blocked_by:
    - rm-l8ck
---

## What

Remove two one-off network costs that every first review of a workspace pays.

1. **Bzlmod resolution in app-owned nested workspaces.** A Bazel workspace whose `MODULE.bazel` has no `MODULE.bazel.lock` next to it (this repository's fixture workspaces `crates/core/tests/fixtures/{swift-bazel,ts-bazel}/{base,head}` and `Tests/ReviewMapCoreTests/Fixtures/kotlin-bazel-indexed/{base,head}`) resolves its module graph from the Bazel Central Registry on the first command in each new output base: downloading `MODULE.bazel` files and `metadata.json` (yanked versions) over the network. Each app-owned workspace exists twice (base and head trees, `Workspaces::workspace_dir` in `crates/core/src/bazel/workspace.rs`), and each has its own output base, so this happens twice per workspace. Bazel then writes `MODULE.bazel.lock` into the app-owned tree, where it survives later reviews because `Workspaces::materialize` only removes files that its manifest lists.
   Change: after the first successful Bazel command of a workspace at one side, when the other side's `MODULE.bazel` (and its included `*.MODULE.bazel` files) has the same content and that side has no lockfile from the revision, copy the lockfile over before its first command. Never write it into the reviewed repository (CORE-002), and never overwrite a lockfile that the revision itself contains.
2. **The scip-java launcher.** `index::kotlin::scip_java_launcher` downloads scip-java (about 100 MB) into `<cache>/tools/scip-java-<version>` on the first Kotlin index. Start that download in the background as soon as a review knows it will index Kotlin (a workspace in scope uses rules_kotlin and has changed Kotlin files), in parallel with the graph queries, and wait for it only when the Kotlin indexer is about to run.

## Why

Measured on 2026-11-17 on this repository (`docs/rebuild-step5-speed.md`, B3 and B7):

- Each first `query //...` of a nested fixture workspace took 10–13 s, 8.6 s of it in Bzlmod module processing (Bazel trace profiles: `fetch module file`, `download file: https://bcr.bazel.build/...`, `getting yanked versions`). The mixed review `8cf8972..046c3e7` paid it 8 times. The Kotlin review paid it twice (11.8–12 s per cold query).
- The scip-java download took 15.9 s of a 72 s cold Kotlin review.
- Both are paid again after the cache is cleared and on every new machine.

## Where

- `crates/core/src/bazel/workspace.rs` (`Workspaces`, after `materialize`), `crates/core/src/session.rs` (`Session::trees`, `Session::refine`), `crates/core/src/index/kotlin.rs` (`scip_java_launcher`, `load`).

## Acceptance criteria

- From empty caches, `8cf8972..046c3e7 --target //app:bundle`: the base-side graph query of each nested workspace takes at most 4 s with a warm root (was 10–13 s), and its Bazel profile shows no `download file` events.
- From empty caches, `046c3e7..bench-kotlin` (a Kotlin function added in the fixture, see rm-l8ck (phase timing and the benchmark script) for how the commit is made): the scip-java download overlaps the graph queries; the review takes at most 60 s (was 72.1 s).
- Reports identical (`diff <(jq -S . a) <(jq -S . b)` empty) to today's for those scenarios.
- No file is written into the reviewed repository (CORE-002; `//crates/core:core_rules` `core_002_analysis_leaves_the_repo_untouched` passes).
- `bazel test //...` passes.

## Dependencies and constraints

- After rm-l8ck (phase timing and the benchmark script). Small and independent; it touches `session.rs` lightly (one call), so merge it after the larger tasks.
- No Statute decision. No `app/src` change.
