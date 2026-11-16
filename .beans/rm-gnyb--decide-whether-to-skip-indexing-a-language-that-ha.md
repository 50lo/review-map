---
# rm-gnyb
title: Skip indexing a language that has no changed file (CORE-003 decision first)
status: todo
type: task
priority: normal
tags:
    - speed
    - decision
created_at: 2026-11-16T21:15:50Z
updated_at: 2026-11-16T21:32:24Z
parent: rm-8hfq
---

## Decision (2026-11-17)

The user chose **option A**: skip building a language's index when the review has no changed file of that language. The Statute decision **D261116-tnmgj** (proposed, actor user, 2026-11-17) changes CORE-003 in `statute/rules/core.md`:

- the statement adds "no file of the language changed in the review, so its index was not built" to the reasons a language ends syntax-only;
- `scope` adds "which languages a review builds an index for (Session::open, Session::refine)";
- a new `protects` case: a Rust-only change in a repository that also has Swift and TypeScript builds no Swift or TypeScript index, both are syntax-only, each has an `index-unavailable` warning saying none of its files changed, nothing is matched by name;
- the preliminary boundary: like "indexes are off", this reason is known from the first report, so the language is `syntax` from then on;
- a new boundary: a file of the language changed when its path is added, deleted or renamed, or its content differs, test and generated files included; files that `reviewmap.yml` excludes don't count; one changed file anywhere in the repository means the language is indexed as it would be otherwise (this reason never leaves part of a language unindexed; TypeScript's existing per-unit indexing, where unchanged units are missed and listed in `index-partial`, is a separate behaviour and stays); it applies whether indexes are on by default, by `reviewmap.yml` or by `--index`.

CORE-003 stays `proposed` until the user approves D261116-tnmgj (`statute approve`, only on the user's explicit approval). Merge the code only after that.

## What

Decide whether a review should skip building a language's index when the change has no file of that language, and if so, implement it for Swift and Kotlin the way TypeScript already behaves. The user has decided (option A, see "Decision" above); the CORE-003 Statute decision still has to be proposed and approved.

Today the languages differ:

- **TypeScript** is indexed only in units that hold a changed TypeScript file (`Session::index_typescript` in `crates/core/src/session.rs` builds `Units.dirs` from changed `.ts`/`.tsx` paths). With none, the language gets no index, ends syntax-only, and the report carries an `index-unavailable` warning whose reason today reads "the change's TypeScript files are in no Yarn Classic project and no Bazel workspace that uses rules_ts", which is misleading when there simply are no changed TypeScript files.
- **Swift and Kotlin** are indexed in every Bazel workspace in scope (`Session::bazel_units` uses `self.in_scope`). When no changed file belongs to an indexed language, for example a Rust-only change, `Session::open` still puts the workspace around the review's starting directory in scope ("Explicit targets belong to the workspace around the directory the review was started from"), so Swift's index is built at both sides. The Swift index is cached by commit (`index::swift::load`, key includes `job.sha`), so every new commit rebuilds it.

Proposed behaviour (option A): a language with no changed file in the review gets no index build; its files are syntax-only; the `index-unavailable` warning says "no <language> file changed in this review, so its index was not built" (TypeScript's reason text is corrected the same way). Option B: keep building it (today's Swift/Kotlin behaviour) and change TypeScript to match, which costs time. Option C: keep today's inconsistent behaviour.

What the reviewer loses with A: the index adds call-level references to edges between components (`max_refs_per_edge`) and the conformer/override context of regions. For a language with no changed file there are no review items of that language, so the structural checks (unused-api, orphaned, untested, conformers) find nothing to check in it anyway; what changes is the detail of edges among unchanged components of that language on the map, which then show only links that syntax proves.

## Why

Measured on 2026-11-17 on this repository (`docs/rebuild-step5-speed.md`, B5), Rust-only change `f1df7b4^..f1df7b4 --target //app:bundle`: from empty caches 89.3 s, of which 69.9 s is building the Swift index at both sides (66 + 5 s) although no Swift file changed; in a warm session 8.3 s, of which 3.3 s is the Swift builds. With option A the cold review would take about 17 s (graph queries and parsing) and the warm one about 3 s.

## Where

- Decision: **needs a Statute decision.** CORE-003 (`statute/rules/core.md`) lists the reasons a language ends without an index: no index could be built, indexing was cancelled, or indexes are turned off. Skipping a language on purpose because none of its files changed is a fourth reason and changes what the main report shows for that language, so it changes the guarantee. If the user picks option A (or B, which changes TypeScript), propose a decision with `statute decide` that adds the reason to CORE-003 and probably a boundary case ("a language with no changed file is not indexed, its files are syntax-only, and the `index-unavailable` warning says so"). TypeScript's current behaviour already skips its index in that case, so the decision should cover it too. Anything created is `proposed`; run `statute approve` only after the user explicitly approves that decision (AGENTS.md, Statute section). No decision was created when this bean was written.
- Code, if A is chosen: `crates/core/src/session.rs` (`Session::open` in-scope rules, `Session::bazel_units`, the `none` reason of `Units`, `Session::refine` before each language), tests in `crates/core/tests/core_rules.rs` (CORE-003 cases).

## Acceptance criteria

- The user has chosen A, B or C, and the choice is recorded in this bean. For A or B, a Statute decision changing CORE-003 is proposed and approved by the user before the code is merged; for C, record why the inconsistency stays.
- If A: `f1df7b4^..f1df7b4 --target //app:bundle` from empty caches takes at most 25 s, runs no Swift index build, and its report differs from today's only in Swift's `resolution` (`syntax` instead of `index`), Swift's `indexedFiles`, the `index-unavailable`/`index-partial`/`checks-held-back` warnings for Swift, and edge reference details among Swift components, each difference listed in the bean when done. A UI-only change still indexes TypeScript and, if a Swift file changed, Swift.
- A CORE-003 test `core_003_a_language_without_changed_files_is_not_indexed` in `crates/core/tests/core_rules.rs` covers the new protects case (a Rust-only change: no index build is attempted for Swift or TypeScript, both `syntax`, each `index-unavailable` warning names the reason) and the boundary (one changed test file of a language means it is indexed). Link it: `statute link CORE-003 crates/core/tests/core_rules.rs#core_003_a_language_without_changed_files_is_not_indexed --test`, and link the code that decides which languages are indexed (`statute link CORE-003 crates/core/src/session.rs#<function>`). Then run the `change` skill (AGENTS.md).
- `bazel test //...` passes.

## Dependencies and constraints

- The user's product decision is made (option A) and D261116-tnmgj is proposed. Before merging code: the user approves D261116-tnmgj. Independent of the other tasks of the epic, but changes `Session::open` and `Session::refine` in `session.rs`, so merge one at a time with them.
- No `app/src` change: the UI already shows `index-unavailable` warnings and per-language coverage.
