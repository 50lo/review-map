---
# rm-n95m
title: Move public API, conformance, and isolation behind Language
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:50:00Z
parent: rm-yuz2
blocking:
    - rm-b7l5
    - rm-nczu
    - rm-c2og
---

Structural review assumes Swift or TypeScript in three places. `isPublic` in Sources/ReviewMapCore/Checks.swift treats every non-Swift declaration as TypeScript and requires `export` on its top-level declaration, so Go, Rust, and Kotlin public declarations would never get `unused-api` findings. `conformers` in Sources/ReviewMapCore/Checks.swift finds conformers by inheritance clauses (`Decl.inherited`), which Go doesn't have (its interfaces are implicit). The isolation on `usedBy` entries comes from Swift attributes (global actors, `nonisolated`, actors, SwiftUI views), which Kotlin expresses differently (`@MainThread`, `withContext(Dispatchers.Main)`).

## Implementation scope
Add to the `Language` protocol in Sources/ReviewMapCore/Language.swift:
- Whether a declaration is public API, given it and its enclosing declarations. Swift and TypeScript keep their current rules; the new languages use their own (rm-nec5, rm-lnvs, rm-mfpz).
- How a language finds the conformers of an interface or protocol. The default is the current inheritance-clause lookup; Go overrides it in rm-b7l5.
- The isolation a reference runs in, given its file and line, so a language can look at the enclosing block as well as the enclosing declarations (Kotlin's dispatcher switches, rm-c2og). Swift keeps its current logic; the default is none.

Move the existing logic behind these, so Checks.swift and the usage computation stay language-neutral.

## Acceptance criteria
- [ ] Checks and usage have no Swift- or TypeScript-specific knowledge left; Swift and TypeScript results are unchanged.
- [ ] Existing ChecksTests and TypeScriptTests pass, including the `MemoryRepository` conformers case.
- [ ] A model of this repo and of the TypeScript fixture is the same before and after.

## Constraints
Three hooks only, shaped by what the new languages need; don't generalize further.
