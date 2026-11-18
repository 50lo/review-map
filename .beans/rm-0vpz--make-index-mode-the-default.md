---
# rm-0vpz
title: Make index mode the default
status: completed
type: task
priority: normal
created_at: 2026-11-15T04:40:01Z
updated_at: 2026-11-17T22:18:04Z
---

## What
Run index mode by default in the reviewmap CLI. A run with neither `--index`/`--no-index` nor `index.enabled` in reviewmap.yml now indexes each language in the change. `--no-index` and `index: {enabled: false}` turn it off.

## Why
Index mode resolves references exactly; name matching over-counts common member names and can't resolve a type name declared in two modules. All five languages (Swift, TypeScript, Go, Rust, Kotlin) now have an indexer, so exact references should be the normal result rather than an opt-in.

## Where
- `Sources/ReviewMapCore/Analyzer.swift`: `Analyzer.run` gates on `enabled != false`; `AnalyzeOptions.init` defaults to `IndexOptions(enabled: false)` so library callers and tests keep name matching unless they ask.
- `Sources/reviewmap/main.swift`: `--index` help text.
- `README.md`: flag table, Index mode section, config sample, limitations.

## Contract
`IndexOptions.enabled: Bool?` — `true` on, `false` off, `nil` follows `index.enabled` in reviewmap.yml and is on when that is unset. The CLI passes nil when no flag is given.

## Constraints
CORE-003 (agreed): a language that falls back to name matching must carry an `index-unavailable` or `index-partial` warning. That is unchanged; a missing toolchain still warns, and the run never fails because of indexing.

## Acceptance criteria
- [x] No flag and no config: index mode runs (test `IndexTests.testIndexModeIsOnUnlessTurnedOff`).
- [x] `index: {enabled: false}` with no flag: no index attempt, no index warning.
- [x] `--no-index` still wins over `enabled: true` in config.
- [x] `AnalyzeOptions` default stays off; fixture snapshots unchanged.
- [x] README and help describe the new default, the opt-out, and what indexing runs.

## Summary of Changes
Flipped the default in `Analyzer.run`, kept the library default off, pinned the name-matching comparison tests to `enabled: false`, added a default/opt-out test, and rewrote the README's default wording with a note on what indexing runs (builds, scripts, tool downloads) and how to turn it off. Full `swift test`: 186 tests, 0 failures.


## Note (2026-11-18): prototype tests removed

The prototype's test suites that this bean added to or ran were removed from the `rebuild` branch to speed up the test runs: `Tests/ReviewMapCoreTests/*.swift` (with the `ReviewMapCoreTests` target in `Package.swift`) and `viewer/src/*.test.ts`. CI now only builds the prototype (`swift build`, `npm run build` in `viewer/`). The fixtures under `Tests/ReviewMapCoreTests/Fixtures/` are kept. The rebuild's tests run with `bazel test //...` (`docs/rebuild-build.md`, "Tests").
