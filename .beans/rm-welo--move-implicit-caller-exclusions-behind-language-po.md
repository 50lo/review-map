---
# rm-welo
title: Move implicit-caller exclusions behind language policy
status: completed
type: task
priority: normal
created_at: 2026-11-05T21:13:39Z
updated_at: 2026-11-06T00:30:00Z
parent: rm-yuz2
blocking:
    - rm-n95m
---

The unused-API and orphaned-code checks skip declarations that a runtime, framework, or language convention calls without naming them. The names and attributes behind that (`body`, `constructor`, `@objc`, `@IBAction`, `@main`, ...) were Swift and TypeScript knowledge in Checks.swift.

## Implementation scope
Add `isImplicitlyCalled(_ decl: Decl) -> Bool` to `Language`, with no default, so each new language states its own entry points (Go's `init` and `main`, Rust's `#[test]`, Kotlin's annotations). Swift and TypeScript implement their rules; Checks.swift keeps only rules that follow from the shared declaration shape: extensions, initializers, protocol requirements, overrides, and members of types that conform to something. Similar-name suggestions use the same hook.

Each language keeps only the names that are meaningful in it: TypeScript no longer skips `init`, `deinit`, `subscript`, `body`, or `main`, and Swift no longer skips `default` or `constructor`.

## Acceptance criteria
- [x] Checks.swift has no language-specific names or attributes.
- [x] Language tests cover Swift and TypeScript implicit-caller rules, and the unused-API check uses the hook.
- [x] Existing checks, language tests, and fixture snapshots pass.
