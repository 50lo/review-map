---
# rm-mgz2
title: Collapse the status bar into one line with a single coverage chip
status: completed
type: task
priority: normal
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T10:52:47Z
parent: rm-w7ge
---

## What

Shrink the status bar under the toolbar (`StatusBar` in `app/src/Shell.tsx`) to one short line. Today it repeats the same information several times.

During analysis the status bar shows all of the following:

1. A spinner and the progress message, cut off at the window width (e.g. "Querying the build graph of every targ…"), and a Cancel link.
2. A stage pill (`stageText`) that wraps to two lines, e.g. "Preliminary: components are Bazel packages and only links that syntax proves are shown."
3. One coverage pill per language (`coverageLabel`). During analysis they all say the same thing: "Swift: preliminary", "Kotlin: preliminary", "TypeScript: preliminary".
4. A pill per language with changed files that aren't analyzed ("N changed Java files not analyzed").
5. The "Indexed / By name" control and "New review" link. These move to the native menu in a separate task of this epic.

Proposed layout, one line:

- **Left:** the spinner (while running) and a short stage name from `report.analysis.stage`. The stages are:
  - `preliminary`: "Preliminary"
  - `graph`: "Build graph ready, indexing"
  - `complete`: "Analysis complete"
  - Also "Cancelled" and "Stopped: <first line of the error>", as today.

  The current progress message follows in muted text, truncated with an ellipsis, with the full text in a tooltip. Cancel stays visible while running.
- **Right:** one coverage chip that summarizes all languages, in the tone of the worst one. Examples:
  - "Indexed" (all `ok`)
  - "3 languages preliminary" (`pending`)
  - "Kotlin: syntax only" (one `warn`)
  - "2 coverage warnings" (several `warn`)
  - Add "· 4 files not analyzed" when there are coverage gaps.

  Clicking the chip opens a popover that lists what the bar shows today: each language's `coverageLabel` text, with its explanation (today's `title`) as visible text rather than a tooltip, the coverage gaps with their sample files, and the long stage explanation (today's `stageText`).

## Why

The reviewer sees three to five pills that say the same thing and a message they can't read in full. This takes a second row of the window and pulls attention away from the map. The only information that matters at a glance is whether the analysis is still running and whether coverage is complete. The details are needed only on demand.

## Where

- `app/src/Shell.tsx`: `StatusBar`, `coverageLabel`, `languageName`.
- `app/src/styles.css`: `.statusbar`, `.status-main`, `.status-coverage`, `.pill`.
- `app/src/App.tsx`: renders `StatusBar`. The props are `job`, `report`, `variant`, `comparing`, `error`, `onVariant`, `onCancel` and `onNewReview`. `onVariant` and `onNewReview` go away when the menu task lands.

## Acceptance criteria

- [x] The status bar is one line high at a window width of 1100 px, in every state: running preliminary, running graph, complete, cancelled, failed.
- [x] The full progress message is readable in a tooltip, and Cancel is reachable while running.
- [x] One coverage chip summarizes all languages. Its tone is the worst of the languages' tones. `coverageLabel` assigns tones but nothing ranks them today; rank them in this order: `warn` above `pending` above `plain` above `ok`. Its popover shows, for every language, the same text and explanation `coverageLabel` produces today, plus the coverage gaps and the stage explanation.
- [x] A language that ended syntax-only or with a partial index is visible on the chip itself (tone and text) without opening the popover. CORE-003 requires the report to say so, and the bar is where the reviewer sees it.
- [x] The summary text and tone come from a pure function, e.g. `coverageSummary(languages, gaps): { text, tone }`, with unit tests for: all indexed, all preliminary, one syntax-only, one partial, several warnings, gaps present.
- [x] `bazel test //app:test` passes, and screenshots of the running and complete states are attached to the bean.

## Dependencies and constraints

- Rule CORE-003 (`statute/rules/core.md`): without an index, a language shows only what syntax proves, and the report says so. Every piece of coverage information shown today (preliminary, syntax only with reason, index covers N of M files, checks not run) must stay reachable, and warnings must stay visible without a click.
- The task "Move the comparison toggle and New review into the app menu" (rm-kifb) in this epic edits the same component. Do that one first, or in the same change, to avoid conflicts.
- Epic: UI improvements (rm-w7ge).


## Summary of Changes

- `app/src/coverage.ts` (new): the status bar's logic as pure functions. `coverageLabel` and `languageName` moved here from `Shell.tsx` unchanged. New: `worstTone` ranks tones `warn` > `pending` > `plain` > `ok`; `coverageSummary(languages, gaps): { text, tone } | null` sums up the chip; `stageName(stage, pending)` gives the short stage name ("Build graph ready" without ", indexing" when no index is still to come); `stageExplanation` is the old `stageText`; `statusLead` gives the left label for running, "Cancelled" and "Stopped: <first line>".
- `coverageSummary`: one warning names its language ("Kotlin: syntax only", "Swift: index covers 8 of 10 files"), several give "N coverage warnings"; otherwise one or "N languages preliminary", then name-based, then "Indexed". Changed files that aren't analyzed add "· N files not analyzed" and count as `warn`, as their pills were, so "Indexed" never shows green while files are missing. An indexed language with held-back checks stays `warn` with "Swift: indexed", as its pill was. No languages and no gaps: no chip.
- `app/src/Shell.tsx`: `StatusBar` is one line. Left: spinner, stage name (the stage explanation, or the cancel explanation, or the full error, in its tooltip), the progress message muted and truncated with the full text in its tooltip, Cancel. Right: the coverage chip (a button; its tooltip lists every language's label) with a popover that shows the stage explanation, each language's `coverageLabel` text with its explanation as visible text (multi-line notes kept), and the gaps with their sample files. The popover closes on an outside click and on Escape (captured, so Escape doesn't also move the map focus). The "Indexed / By name" control and "New review" stay, slightly more compact, until rm-kifb moves them to the app menu; rm-kifb is not started.
- `app/src/styles.css`: the bar is 26 px high and `nowrap`; the message gives way first, then the error text. `.pill.pending` no longer wraps (that caused the two-line stage pill). New `.coverage-chip` and `.coverage-popover`.
- `app/src/coverage.test.ts`: 19 tests, including all indexed, all preliminary, one syntax-only, one partial, held-back checks, several warnings, gaps present, gaps only, no coverage, the tone ranking, the stage names and explanations, and the cancelled, failed and complete leads. `bazel test //app:test` passes (135 tests), and `//app:ts` type-checks.
- Checked visually in the dev preview at 1100 × 700 with the 0cd5916..0e57fa4 report: complete (light, and with the popover in light and dark), and running preliminary, running graph (with the popover), cancelled and failed, each driven by emitting review events into the mocked backend with edited copies of the report. The bar measured 26 px high in every state, with no horizontal scroll. Not checked in the app built by `scripts/build-app.sh`. Screenshots: `rm-mgz2-screenshots/` in the side-session notes folder (`~/Library/Application Support/Claude/side-session-notes/local_685f33ac-fe16-46f2-b06b-37696ac964e2/`).
- Statute: no rules are linked to these files and `statute check` is clean. The tone ranking is a UI choice, not a product rule, so no decision was recorded; CORE-003's visibility holds because every warning tone shows on the chip.
