---
# rm-mgz2
title: Collapse the status bar into one line with a single coverage chip
status: todo
type: task
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T09:57:22Z
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

- [ ] The status bar is one line high at a window width of 1100 px, in every state: running preliminary, running graph, complete, cancelled, failed.
- [ ] The full progress message is readable in a tooltip, and Cancel is reachable while running.
- [ ] One coverage chip summarizes all languages. Its tone is the worst of the languages' tones. `coverageLabel` assigns tones but nothing ranks them today; rank them in this order: `warn` above `pending` above `plain` above `ok`. Its popover shows, for every language, the same text and explanation `coverageLabel` produces today, plus the coverage gaps and the stage explanation.
- [ ] A language that ended syntax-only or with a partial index is visible on the chip itself (tone and text) without opening the popover. CORE-003 requires the report to say so, and the bar is where the reviewer sees it.
- [ ] The summary text and tone come from a pure function, e.g. `coverageSummary(languages, gaps): { text, tone }`, with unit tests for: all indexed, all preliminary, one syntax-only, one partial, several warnings, gaps present.
- [ ] `bazel test //app:test` passes, and screenshots of the running and complete states are attached to the bean.

## Dependencies and constraints

- Rule CORE-003 (`statute/rules/core.md`): without an index, a language shows only what syntax proves, and the report says so. Every piece of coverage information shown today (preliminary, syntax only with reason, index covers N of M files, checks not run) must stay reachable, and warnings must stay visible without a click.
- The task "Move the comparison toggle and New review into the app menu" (rm-kifb) in this epic edits the same component. Do that one first, or in the same change, to avoid conflicts.
- Epic: UI improvements (rm-w7ge).
