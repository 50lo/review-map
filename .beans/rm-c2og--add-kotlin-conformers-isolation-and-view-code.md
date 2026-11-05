---
# rm-c2og
title: Add Kotlin conformers, isolation, and view code
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-aks4
---

## Implementation scope
- Conformers come from supertype lists through the default lookup. An interface member with a body is a default; an abstract class's abstract members count as requirements.
- Isolation hook from rm-n95m: a reference runs on the main thread inside `@MainThread` or `@UiThread` declarations, inside `withContext(Dispatchers.Main)` blocks, and inside `View`, `Activity`, and `Fragment` subclasses. Everything else has no known isolation.
- `isViewCode`: `@Composable` functions and members of `View`, `Activity`, and `Fragment` subclasses.

## Acceptance criteria
- [ ] A fixture interface that gains an abstract member produces a `conformers` finding for the class without it.
- [ ] `usedBy` entries in a `@MainThread` caller carry main-thread isolation, and the structural review prompt shows it.
- [ ] Composable functions are excluded from region control-flow risk, as SwiftUI views are.
