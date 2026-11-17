---
# rm-tnty
title: Make the viewer's language list one table
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-17T22:18:04Z
parent: rm-yuz2
blocking:
    - rm-1w6o
    - rm-jf7h
    - rm-j0dk
---

Adding a language to the viewer currently means editing several places: the `Language` union, `ORDER`, and `languageOfPath` in viewer/src/languages.ts, the component kinds in `componentLanguages`, the icons in viewer/src/LanguageBadges.tsx, the extension map in `languageOf` in viewer/src/highlight.ts, and the TypeScript-only `TS_KINDS` and `kindLabel` in viewer/src/graph.ts.

## Implementation scope
Put each language's facts in one table entry in viewer/src/languages.ts: id, display name, source extensions, manifest and lockfile patterns, component kinds, icon, Shiki language per extension, and review item kind names (with the `var` -> property/variable rule as a per-language function where needed). Derive the existing functions from the table. Swift and TypeScript are the only entries; no behavior change.

## Acceptance criteria
- [x] Swift and TypeScript each live in one table entry, and the functions above read from it.
- [x] Existing viewer tests pass unchanged (languages.test.ts, graph.test.ts, levels.test.ts), plus a test that every table entry's extensions resolve to its Shiki language.
- [x] `npm run build` and `npm test` pass in viewer/.

## Constraints
No model change. Keep the table plain data; no registry classes.

## Validation

84 viewer tests pass, including the unchanged existing tests and 23 language-table tests. Production and single-file builds pass. Implementation and independent review found no behavior changes.


## Note (2026-11-18): prototype tests removed

The prototype's test suites that this bean added to or ran were removed from the `rebuild` branch to speed up the test runs: `Tests/ReviewMapCoreTests/*.swift` (with the `ReviewMapCoreTests` target in `Package.swift`) and `viewer/src/*.test.ts`. CI now only builds the prototype (`swift build`, `npm run build` in `viewer/`). The fixtures under `Tests/ReviewMapCoreTests/Fixtures/` are kept. The rebuild's tests run with `bazel test //...` (`docs/rebuild-build.md`, "Tests").
