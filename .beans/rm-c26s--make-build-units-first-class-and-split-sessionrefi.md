---
# rm-c26s
title: Make build units first-class and split Session::refine
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-19T00:00:00Z
parent: rm-b0sh
blocked_by:
    - rm-o0mk
    - rm-wb96
---

Give every index unit a build system, list units per language, and split `Session::refine` so a language is no longer "Bazel only". Part of the xcodebuild epic (rm-b0sh).

## Background

`Session::refine` in `crates/core/src/session.rs` (about lines 360-569) asks Bazel for the build graph and then builds each language's index in a hard-coded block. Swift and Kotlin are `bazel_only`: with no Bazel workspace in the change, or no Bazel binary, each gets a final note such as "the change touches no Bazel workspace, and phase 1 indexes Bazel projects only". `bazel_units` gives a file to a Bazel workspace by containment alone. TypeScript already mixes two kinds of unit (rules_ts workspaces and Yarn roots), but inside `index_typescript`. The shared engine `index_workspaces` (one `SideIndex` per unit and side; a unit's failure becomes `index-partial`, every unit failing becomes `index-unavailable`; CORE-003 in `statute/rules/core.md`) is good and stays.

## What

1. New `crates/core/src/units.rs`:
   ```rust
   pub enum System { Bazel, Xcode, PackageManager }
   pub struct Unit { pub id: String, pub system: System, pub name: String }
   pub struct Units<'u> {
       pub units: Vec<Unit>,
       pub of: Box<dyn Fn(Side, &str) -> Option<String> + 'u>,  // the unit id a file belongs to at a side
       pub exists: Box<dyn Fn(&SideSource, &str) -> bool + 'u>, // whether a unit exists at a side
       pub none: String,                                        // why there is no index when no unit has the language's files
   }
   ```
   `id` is a repo-relative directory or container path; `name` is how warnings call the unit. It replaces the private `Units` near the end of `session.rs`.
2. One function per language that lists its units, moved out of `Session`: `index::swift::units`, `index::kotlin::units`, `index::typescript::units` (today's `bazel_units` and the first half of `index_typescript`). Each applies the claim rule:
   - Ownership decides, per file and per side (which is why `of` takes the side); the rule is the Statute decision of rm-eeww. A file that a Bazel target of that side's build graph lists in its sources belongs to that Bazel workspace's unit.
   - A Bazel workspace is a unit of a language, and is asked for its graph, only when it uses that language's rules, checked with `bazel::uses_module` on committed files: Swift `rules_swift`, `rules_apple`, `rules_xcodeproj` or `rules_swift_package_manager`; Kotlin `rules_kotlin`; TypeScript `aspect_rules_ts`. This is a filter for which workspaces to query, not the ownership test.
   - A Swift or Kotlin file that no Bazel target lists, inside a workspace that uses the language's rules, still maps to that workspace for now, so it is reported under it as not indexed (today's behaviour). rm-849t puts an Xcode container before this fallback: a Swift file no Bazel target lists that an Xcode target or local package owns goes to the container, wherever it sits.
   - Other TypeScript files go to the innermost package-manager root, as today.
3. One function per language that builds a unit at a side and dispatches on `unit.system` (today's closures in `refine` and `index_typescript`). They take a shared `IndexContext`: repository root, both `SideSource`s, the lazily made trees behind a mutex, the Bazel tool and arguments, the scopes by (side, workspace), cache directories, `emit`, `cancel`.
4. `Session::refine` becomes: the Bazel graph step, run when any unit in scope is a Bazel unit; then `index_units(language)` per language, in the order Swift, Kotlin, TypeScript, emitting a report after each as today. `index_workspaces` is renamed `index_units` and otherwise unchanged. The `bazel_only` notes go: a missing Bazel binary, or a scope of `//...` for Swift, is the failure of that Bazel unit (as TypeScript already does), and a language without any unit gets its own `none` sentence.

## Why

Without it there is no place to say "this Swift file is built by Xcode", and each new build system grows one 200-line function.

## Where

`crates/core/src/session.rs`, new `crates/core/src/units.rs`, `crates/core/src/index/{swift,kotlin,typescript}.rs`, `crates/core/src/lib.rs`, tests in `crates/core/tests/`.

## Acceptance criteria

- `bazel_fixtures.rs`, `typescript_fixtures.rs`, `core_rules.rs`, `swift_rules.rs`, `llm.rs` pass. Report contents are unchanged for every fixture.
- Warning texts change only here, each asserted by a test: Swift or Kotlin in a repository with no Bazel workspace gets the language's `none` sentence; `without_bazel_the_review_stays_syntax_only` still ends syntax-only with a reason that names Bazel.
- New unit test: a tree with a root `MODULE.bazel` whose only `bazel_dep` is `aspect_rules_ts`, and `ios/Sources/A.swift`, gives no Bazel unit for Swift. And: with a graph at head in which `//tools:Gen` lists `tools/Gen.swift`, and a graph at base that does not, `of(Side::Head, "tools/Gen.swift")` is owned by the workspace through its target and `of(Side::Base, …)` falls to the containment fallback (the test asserts the two paths are distinguishable, since rm-849t inserts Xcode between them).
- CORE-003's scope names `Session::refine` and `Session::open`: the Statute `change` skill has been run and its code links updated (AGENTS.md). `bazel test //...` passes.

## Dependencies and constraints

Blocked by rm-o0mk (the trees module) and rm-wb96 (the TypeScript `Setup`). The order in which results are taken (units in order, head before base) must stay, so reports do not depend on timing.
