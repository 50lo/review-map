---
# rm-c2og
title: Add Kotlin conformers, isolation, and view code
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-07T01:04:30Z
parent: rm-aks4
---

## Implementation scope
- Conformers come from supertype lists through the default lookup. An interface member with a body is a default; an abstract class's abstract members count as requirements.
- Isolation hook from rm-n95m: the innermost dispatcher block wins. Inside `withContext`, `launch`, or `async` with a `Dispatchers.X` argument, a reference is main-thread isolated for `Dispatchers.Main` and has no known isolation for any other dispatcher. Outside such blocks, it is main-thread isolated inside `@MainThread` or `@UiThread` declarations and `View`, `Activity`, and `Fragment` subclasses. Everything else has no known isolation.
- `isViewCode`: `@Composable` functions and members of `View`, `Activity`, and `Fragment` subclasses.

## Acceptance criteria
- [x] A fixture interface that gains an abstract member produces a `conformers` finding for the class without it.
- [x] `usedBy` entries in a `@MainThread` caller carry main-thread isolation, and the structural review prompt shows it.
- [x] A reference inside `withContext(Dispatchers.IO)` in an `Activity` carries no isolation.
- [x] Composable functions are excluded from region control-flow risk, as SwiftUI views are.

Implemented lexical dispatcher regions with innermost-block precedence, Android main-thread declaration conventions, and Compose view-risk handling. Kotlin conformer lookup uses package/import and enclosing-type identity; only actual class members satisfy requirements. Six focused structural tests plus the Kotlin fixture pass locally (7 tests), covering interface defaults, abstract class requirements, import aliases, same-name types in different packages, nested interfaces, dispatcher overrides, usage/prompt isolation, and Compose region risk. Independent review findings were fixed and covered by regressions; temporary fixture repositories are removed by tests.
