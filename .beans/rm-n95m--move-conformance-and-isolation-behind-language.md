---
# rm-n95m
title: Move conformance and isolation behind Language
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-yuz2
blocking:
    - rm-b7l5
    - rm-nczu
    - rm-c2og
---

Structural review assumes Swift in two places. `conformers` in Sources/ReviewMapCore/Checks.swift finds conformers by inheritance clauses (`Decl.inherited`), which Go doesn't have (its interfaces are implicit). The isolation on `usedBy` entries comes from Swift attributes (global actors, `nonisolated`, actors, SwiftUI views), which Kotlin expresses differently (`@MainThread`, `withContext(Dispatchers.Main)`).

## Implementation scope
Add to the `Language` protocol in Sources/ReviewMapCore/Language.swift:
- How a language finds the conformers of an interface or protocol. The default is the current inheritance-clause lookup; Go overrides it in rm-b7l5.
- The isolation a reference runs in, given the enclosing declarations. Swift keeps its current logic; the default is none.

Move the Swift logic behind these, so Checks.swift and the usage computation stay language-neutral.

## Acceptance criteria
- [ ] Checks and usage have no Swift-specific knowledge left; Swift and TypeScript results are unchanged.
- [ ] Existing ChecksTests and TypeScriptTests pass, including the `MemoryRepository` conformers case.
- [ ] A model of this repo and of the TypeScript fixture is the same before and after.

## Constraints
Two hooks only, shaped by what Go and Kotlin need; don't generalize further.
