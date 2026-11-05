---
# rm-welo
title: Move implicit-caller exclusions behind language policy
status: draft
type: task
created_at: 2026-11-05T21:13:39Z
updated_at: 2026-11-05T21:13:39Z
parent: rm-yuz2
blocking:
    - rm-n95m
---

The original acceptance criterion in rm-n95m requires Checks and usage to contain no Swift- or TypeScript-specific knowledge. Its three planned hooks cover public API, conformance, and isolation, but `Sources/ReviewMapCore/Checks.swift` still owns `implicitNames`, `entryAttributes`, the `IB` prefix rule, and `calledImplicitly`. These exclusions prevent false unused/orphaned-code findings for declarations invoked by frameworks, runtimes, or language conventions. They must not be removed without replacing their behavior.

PR #23 preserves those exclusions and implements the three planned hooks. This draft tracks the remaining criterion without treating the three-hook limit as authorization for another hook. The original criterion stays unchecked in rm-n95m until this work is implemented or the scope is explicitly changed.

## Implementation scope

Review how to move implicit-caller classification to each language without changing existing Swift and TypeScript results. The affected boundaries are `Language.swift`, `Checks.swift`, `Swift/SwiftLanguage.swift`, and `TypeScript/TypeScriptLanguage.swift`; test coverage belongs in `ChecksTests.swift` and `LanguageTests.swift`. See docs/plan.md, "Adding a language", and rm-n95m for the existing three-hook contract.

A concrete contract to evaluate before implementation is:

```swift
func isImplicitlyCalled(_ decl: Decl, enclosing: [Decl]) -> Bool
```

`enclosing` would contain the parent chain, innermost first. The result would tell unused/orphaned-code checks that a declaration may be invoked without a named reference. This is a proposal, not an approved fourth hook; consider whether a smaller language-owned policy can express the same behavior and record the chosen contract before implementing it.

## Acceptance criteria

- [ ] Record the chosen contract and the explicit resolution of rm-n95m's three-hook constraint.
- [ ] Move the existing language-specific names, runtime attributes, and prefix exclusions out of shared checks while retaining their behavior for Swift and TypeScript.
- [ ] Cover Swift runtime/framework entry points and TypeScript constructor/default-export handling, plus ordinary unreferenced declarations that should still be reported.
- [ ] Existing checks, language tests, and Swift/TypeScript fixture snapshots pass; compare complete models before and after.
- [ ] Reassess the original broad criterion in rm-n95m and complete it only when satisfied.

## Dependencies and constraints

Build on the three hooks in PR #23. This item remains draft until its contract and scope are settled. Preserve current implicit-caller exclusions until their replacement is verified. No model/schema change is expected.
