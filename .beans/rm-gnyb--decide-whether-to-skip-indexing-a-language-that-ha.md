---
# rm-gnyb
title: Decide whether to skip indexing a language that has no changed file
status: draft
type: task
priority: normal
tags:
    - speed
    - decision
created_at: 2026-11-16T21:15:50Z
updated_at: 2026-11-16T21:15:50Z
parent: rm-8hfq
---

## What

Decide whether a review should skip building a language's index when the change has no file of that language, and if so, implement it for Swift and Kotlin the way TypeScript already behaves. **This needs the user's decision before any code is written.**

Today the languages differ:

- **TypeScript** is indexed only in units that hold a changed TypeScript file (`Session::index_typescript` in `crates/core/src/session.rs` builds `Units.dirs` from changed `.ts`/`.tsx` paths). With none, the language gets no index, ends syntax-only, and the report carries an `index-unavailable` warning whose reason today reads "the change's TypeScript files are in no Yarn Classic project and no Bazel workspace that uses rules_ts", which is misleading when there simply are no changed TypeScript files.
- **Swift and Kotlin** are indexed in every Bazel workspace in scope (`Session::bazel_units` uses `self.in_scope`). When no changed file belongs to an indexed language, for example a Rust-only change, `Session::open` still puts the workspace around the review's starting directory in scope ("Explicit targets belong to the workspace around the directory the review was started from"), so Swift's index is built at both sides. The Swift index is cached by commit (`index::swift::load`, key includes `job.sha`), so every new commit rebuilds it.

Proposed behaviour (option A): a language with no changed file in the review gets no index build; its files are syntax-only; the `index-unavailable` warning says "no <language> file changed in this review, so its index was not built" (TypeScript's reason text is corrected the same way). Option B: keep building it (today's Swift/Kotlin behaviour) and change TypeScript to match, which costs time. Option C: keep today's inconsistent behaviour.

What the reviewer loses with A: the index adds call-level references to edges between components (`max_refs_per_edge`) and the conformer/override context of regions. For a language with no changed file there are no review items of that language, so the structural checks (unused-api, orphaned, untested, conformers) find nothing to check in it anyway; what changes is the detail of edges among unchanged components of that language on the map, which then show only links that syntax proves.

## Why

Measured on 2026-11-17 on this repository (`docs/rebuild-step5-speed.md`, B5), Rust-only change `f1df7b4^..f1df7b4 --target //app:bundle`: from empty caches 89.3 s, of which 69.9 s is building the Swift index at both sides (66 + 5 s) although no Swift file changed; in a warm session 8.3 s, of which 3.3 s is the Swift builds. With option A the cold review would take about 17 s (graph queries and parsing) and the warm one about 3 s.

## Where

- Decision: CORE-003 (`statute/rules/core.md`) already describes the outcome of a language without an index (syntax-only, `index-unavailable` warning naming the language and the reason), and its boundary says the resolution is syntax "once it is known there will be none". So the rule text need not change. Whether to accept less detail on unchanged languages is a product choice; if the user wants it recorded, propose a Statute decision with `statute decide` (it may add a boundary case: "a language with no changed file is not indexed, and the report says so"). Don't approve it in the same session without the user's explicit approval (AGENTS.md, Statute section).
- Code, if A is chosen: `crates/core/src/session.rs` (`Session::open` in-scope rules, `Session::bazel_units`, the `none` reason of `Units`, `Session::refine` before each language), tests in `crates/core/tests/core_rules.rs` (CORE-003 cases).

## Acceptance criteria

- The user has chosen A, B or C, and the choice is recorded in this bean (and in a Statute decision if they want one).
- If A: `f1df7b4^..f1df7b4 --target //app:bundle` from empty caches takes at most 25 s, runs no Swift index build, and its report differs from today's only in Swift's `resolution` (`syntax` instead of `index`), Swift's `indexedFiles`, the `index-unavailable`/`index-partial`/`checks-held-back` warnings for Swift, and edge reference details among Swift components, each difference listed in the bean when done. A UI-only change still indexes TypeScript and, if a Swift file changed, Swift.
- If A: a CORE-003 test asserts that a language with no changed file is syntax-only with an `index-unavailable` warning that names that reason.
- `bazel test //...` passes.

## Dependencies and constraints

- Blocked on the user's decision. Independent of the other tasks of the epic, but changes `Session::open` and `Session::refine` in `session.rs`, so merge one at a time with them.
- No `app/src` change: the UI already shows `index-unavailable` warnings and per-language coverage.
