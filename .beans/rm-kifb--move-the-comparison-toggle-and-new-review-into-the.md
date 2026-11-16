---
# rm-kifb
title: Move the comparison toggle and New review into the app menu
status: todo
type: task
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T09:57:22Z
parent: rm-w7ge
---

## What

Take the "Indexed / By name" segmented control and the "New review" link out of the status bar (`StatusBar` in `app/src/Shell.tsx`). Make them items in the app's native macOS menu:

- **File → New Review…** (⌘N): does what the "New review" link does today. It returns to the start screen (`onNewReview` in `app/src/App.tsx`). It is disabled while a review is running.
- **View → Show Name-Matched Comparison** (a checkable item): does what the "By name" button does today. It calls `compare("name-based")` in `App.tsx`, which fetches the comparison report with `backend.nameBasedReport()`. Unchecking it calls `compare("indexed")`. It is disabled while a review is running or the comparison report is still loading.

While the comparison report is on screen, show a banner above the map: "Showing the name-matched comparison report: references are matched by name, not by the index." Include a "Back to indexed" button. Without the banner, a reviewer who turned it on from the menu could forget they are looking at name-matched links.

Proposed contract between the Rust app and the UI:

- In `app/src-tauri/src/lib.rs`, build the menu in `setup`.
  - Keep the default app menu (About, Hide, Quit and so on) and the Edit menu, so copy and paste keep working.
  - "Quit Review Map" must keep running the exit path that stops the app's Bazel servers.
  - Menu item ids: `new-review` and `compare-name-based`.
  - On click, emit an event `menu` with payload `{ "id": string }`.
- New command `set_menu_state` with the argument `{ canStartNew: bool, canCompare: bool, nameBased: bool }`. It enables or disables the two items and sets the check mark.
- In `app/src/backend.ts`, add:
  - `onMenu(cb: (id: string) => void): Promise<() => void>`
  - `setMenuState(s: { canStartNew: boolean; canCompare: boolean; nameBased: boolean }): Promise<void>`
- `app/src/dev-mock.ts`: implement both as no-ops so the browser dev preview keeps working.
- `App.tsx` calls `setMenuState` whenever `job.running`, `comparing` or `variant` changes, and handles the two ids from `onMenu`.

## Why

The "Indexed / By name" control is a validation tool. `docs/rebuild-phase1-proposal.md` asks for "a comparison control during validation" so the user can compare indexed and non-indexed results for the same revisions. It isn't part of reviewing a change, but today it sits next to the review controls and invites clicks that show misleading name-matched links. "New review" is an app-level action that doesn't belong in a status bar. Moving both frees the status bar for analysis status (a separate task in this epic shrinks the status bar to one line).

## Where

- `app/src-tauri/src/lib.rs`: `tauri::Builder::default()` and `setup` (around line 455). There is no custom menu today.
- `app/src/backend.ts`, `app/src/dev-mock.ts`.
- `app/src/App.tsx`: `variant`, `comparing`, `compare`, and the `StatusBar` props `onVariant` and `onNewReview`.
- `app/src/Shell.tsx`: remove the segmented control and the link from `StatusBar`.

## Acceptance criteria

- [ ] File → New Review… and ⌘N return to the start screen. They are disabled while a review is running.
- [ ] View → Show Name-Matched Comparison switches to the comparison report and back. Its check mark matches what is on screen. It is disabled while running or while the comparison is loading. A failure to load shows the error, as today.
- [ ] While the comparison report is shown, the banner is visible on every level (map, interface view, review item), and "Back to indexed" returns to the indexed report.
- [ ] The status bar no longer has the segmented control or the "New review" link.
- [ ] Quit still stops the app's Bazel servers. Check that `<REVIEWMAP_HOME>/cache/logs/app.log` records the shutdown, or that no Bazel server for the app's output bases keeps running after Quit.
- [ ] The dev preview (`REVIEWMAP_REPORT=<file> bazel run //app:dev`) still loads.
- [ ] `bazel test //...` passes.

## Dependencies and constraints

- Keep the comparison control. The phase-1 proposal requires it during validation. This task moves it; it doesn't remove it.
- The task "Collapse the status bar into one line with a single coverage chip" (rm-mgz2) in this epic edits `StatusBar` too. Do this task first, or both together.
- To drive the app window with computer use, use the bundle built by `scripts/build-app.sh` (bundle id `dev.reviewmap.app`). Typing into its web view drops characters, so start reviews with the `reviewmap` command, not the form.
- Epic: UI improvements (rm-w7ge).
