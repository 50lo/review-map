---
# rm-c2og
title: Add Kotlin conformers, isolation, and view code
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:50:00Z
parent: rm-aks4
---

## Implementation scope
- Conformers come from supertype lists through the default lookup. An interface member with a body is a default; an abstract class's abstract members count as requirements.
- Isolation hook from rm-n95m: the innermost dispatcher block wins. Inside `withContext`, `launch`, or `async` with a `Dispatchers.X` argument, a reference is main-thread isolated for `Dispatchers.Main` and has no known isolation for any other dispatcher. Outside such blocks, it is main-thread isolated inside `@MainThread` or `@UiThread` declarations and `View`, `Activity`, and `Fragment` subclasses. Everything else has no known isolation.
- `isViewCode`: `@Composable` functions and members of `View`, `Activity`, and `Fragment` subclasses.

## Acceptance criteria
- [ ] A fixture interface that gains an abstract member produces a `conformers` finding for the class without it.
- [ ] `usedBy` entries in a `@MainThread` caller carry main-thread isolation, and the structural review prompt shows it.
- [ ] A reference inside `withContext(Dispatchers.IO)` in an `Activity` carries no isolation.
- [ ] Composable functions are excluded from region control-flow risk, as SwiftUI views are.
