---
# rm-eeww
title: Record which build system indexes a file as a Statute decision
status: todo
type: task
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-19T00:00:00Z
parent: rm-b0sh
---

Propose, with the `statute:decide` skill, the rule for which build system's index speaks for a source file, and get the user's approval. Part of the xcodebuild epic (rm-b0sh).

## What

Propose a decision that adds this boundary to CORE-003 in `statute/rules/core.md` (or a new CORE rule, whichever the skill's gates favour):

> A file is indexed by one build system, decided per side by ownership. A file that a Bazel target of the review scope lists in its sources is indexed by Bazel. Any other Swift file that an Xcode target or a local Swift package owns is indexed by its Xcode container (a workspace, or a project that no workspace contains), wherever the file is, including inside a Bazel workspace. A file both own is indexed by Bazel, and its component is the Bazel target. A file neither owns is syntax-only and is listed in an `index-partial` warning. Other TypeScript files are indexed by their innermost package-manager root. A Bazel workspace is queried for a language only when it uses that language's rules (Swift: rules_swift, rules_apple, rules_xcodeproj or rules_swift_package_manager; Kotlin: rules_kotlin; TypeScript: aspect_rules_ts).

The four situations of a repository where Bazel and Xcode coexist:

| Swift file is built by | Index | Component |
| --- | --- | --- |
| Bazel only | Bazel | its Bazel target |
| Xcode only, outside every Bazel workspace | Xcode | its Xcode or package target |
| Xcode only, inside a Bazel workspace (a root `MODULE.bazel` builds Swift tools, `ios/App.xcodeproj` builds the app) | Xcode | its Xcode or package target |
| both | Bazel | its Bazel target; the Xcode target is not shown for this file |

Cases the rule's `protects` and `boundary` should carry: the four rows above; without a build graph for a workspace (Bazel not found, the query failed), a file both own is indexed by Xcode; the graph covers the review scope only, so a file whose only Bazel owner is outside the scope targets counts as not owned by Bazel; ownership is per side, so a change that moves a file from an Xcode target to a Bazel target has it indexed by Xcode at base and by Bazel at head; while the graph is still to come, a file both own is shown under its Xcode target and moves to its Bazel target at the graph stage; when the two builds disagree about a file both own (conditional compilation, module names), the report shows Bazel's view.

Before asking for approval, check it as AGENTS.md requires: what valid case would it reject (for example a Bazel workspace that builds Swift through a custom rule set without rules_swift), what invalid case would it allow, and whether a reviewer would rather see Xcode's view of a file both build (no override is planned), and whether its meaning changes with missing data (a workspace at one side only), time or partial failure. Add to the rule only the answers that change it.

## Why

Until now every Swift and Kotlin file was Bazel's by definition, and the code decided TypeScript's case locally. With Xcode as a second way to build Swift, a repository can hold both (a root `MODULE.bazel` for web tooling beside `ios/App.xcodeproj`), and the choice changes what a report shows as exact. AGENTS.md says rules change only together with a proposed decision that a human approves; they are never edited to match the code.

## Where

`statute/` through the `statute` CLI only (`statute decide`, then `statute approve` after the user approves in a session). Never edit `agreed` or `built` by hand.

## Acceptance criteria

- A proposed decision exists that lists the rule text above (as amended by the checks).
- The user has approved it explicitly in a session, and `statute approve` has recorded that, before the xcodebuild index (rm-849t) merges.

## Dependencies and constraints

The rule is implemented for Bazel and package managers by rm-c26s and for Xcode by rm-849t; the decision can be proposed in parallel with rm-c26s.
