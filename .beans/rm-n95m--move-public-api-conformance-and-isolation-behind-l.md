---
# rm-n95m
title: Move public API, conformance, and isolation behind Language
status: in-progress
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T21:14:12Z
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
- [x] Existing ChecksTests and TypeScriptTests pass, including the `MemoryRepository` conformers case.
- [x] A model of this repo and of the TypeScript fixture is the same before and after.

## Constraints
Three hooks only, shaped by what the new languages need; don't generalize further.

`Regions.swift` uses the same conformer-discovery hook for conformer context. Override context reuses the builder's syntax-based inheritance index; view-code classification retains its inherited-type facts. Preserve the current behavior of each consumer, including their different visibility filters and interface-name lookup.


## Hook contract

The three `Language` methods are:

```swift
func isPublicAPI(_ decl: Decl, enclosing: [Decl]) -> Bool
func conformers(of interface: Pair, requirement: Pair?,
                in builder: ModelBuilder, for use: ConformanceUse) -> [Conformer]
func isolation(in file: ParsedFile, line: Int) -> String?
```

- `enclosing` contains the declaration's parent chain, innermost first. Public API classification is used by unused-code checks.
- `ConformanceUse` has `check` and `context` cases. Each `Conformer` contains `declaration: Located` and `implementations: [Located]`. The requirement is nil for whole-interface context. For a requested requirement, an empty implementation list means it is missing; consumers use the supplied matches. This lets a language reject a same-name method with the wrong arity.
- The conformance hook receives the matched interface and the builder's base and head trees, declaration pairs, and all components. The default preserves the existing inheritance, visibility, default-extension, and implementation lookup rules of each consumer. An implicit-conformance implementation can return candidates without a head dependency edge and select implementations from the appropriate component.
- Isolation uses a parsed file and a 1-based reference line. The default returns nil, including for TypeScript. Swift retains its declaration isolation rules. Kotlin can record dispatcher ranges during parsing when rm-c2og is implemented; no source reader or speculative range fields are added here.


## Validation

- The full Swift suite passes: 90 tests with `NSUnbufferedIO=YES swift test --parallel --num-workers 2`, including the seven hook tests, ChecksTests, TypeScriptTests, index suites, and unchanged snapshots.
- Complete change models match the pre-refactor analyzer for this repo (`e6fda05` to `e7c70c6`), the basic Swift fixture, and the TypeScript fixture.
- The hook tests cover wrong-arity methods, same-named types in unrelated components, base/head parsed-file isolation, and name/index usage paths. The original broad acceptance criterion remains open as described below.


## Remaining acceptance work

The three planned hooks are implemented, but the original first acceptance criterion is not fully satisfied: `Checks.swift` still contains the implicit-caller names, runtime attributes, and prefix exclusions. Draft rm-welo tracks moving those behind language policy and resolving the three-hook constraint before any additional hook is implemented. The criterion stays unchecked, and rm-n95m and rm-yuz2 remain in progress. The existing exclusions stay active to avoid false unused/orphaned-code findings.

Review also identified the old shared function's accidental interpretation of TypeScript Actor-suffixed decorators as Swift isolation. TypeScript now uses the planned nil default. This corrects those decorator cases; the recorded repository model and Swift/TypeScript fixture models remain unchanged.
