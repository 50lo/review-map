---
# rm-kifb
title: Move the comparison toggle and New review into the app menu
status: completed
type: task
priority: normal
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T12:01:47Z
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

- [x] File → New Review… and ⌘N return to the start screen. They are disabled while a review is running.
- [x] View → Show Name-Matched Comparison switches to the comparison report and back. Its check mark matches what is on screen. It is disabled while running or while the comparison is loading. A failure to load shows the error, as today.
- [x] While the comparison report is shown, the banner is visible on every level (map, interface view, review item), and "Back to indexed" returns to the indexed report.
- [x] The status bar no longer has the segmented control or the "New review" link.
- [x] Quit still stops the app's Bazel servers. Check that `<REVIEWMAP_HOME>/cache/logs/app.log` records the shutdown, or that no Bazel server for the app's output bases keeps running after Quit.
- [x] The dev preview (`REVIEWMAP_REPORT=<file> bazel run //app:dev`) still loads.
- [x] `bazel test //...` passes.

## Dependencies and constraints

- Keep the comparison control. The phase-1 proposal requires it during validation. This task moves it; it doesn't remove it.
- The task "Collapse the status bar into one line with a single coverage chip" (rm-mgz2) in this epic edits `StatusBar` too. Do this task first, or both together.
- To drive the app window with computer use, use the bundle built by `scripts/build-app.sh` (bundle id `dev.reviewmap.app`). Typing into its web view drops characters, so start reviews with the `reviewmap` command, not the form.
- Epic: UI improvements (rm-w7ge).


## Summary of Changes

- `app/src-tauri/src/menu.rs` (new): builds the menu bar in `setup`. It is Tauri's default macOS menu item for item (app menu with About, Hide and the predefined Quit; Edit; Window; Help), plus **File → New Review…** (id `new-review`, ⌘N) and **View → Show Name-Matched Comparison** (id `compare-name-based`, a check item). Both start disabled. A click on either emits the event `menu` with payload `{ "id": string }`; the predefined items act by themselves.
- `app/src-tauri/src/lib.rs`: registers the menu (if it can't be built, the app logs it and runs without it) and the new command `set_menu_state(state: { canStartNew, canCompare, nameBased })`, which enables the two items and sets the check mark. Each call is written to the app log (`ui: menu state: …`).
- `app/src/backend.ts`: `MenuState`, `setMenuState(s)` and `onMenu(cb)`. `app/src/dev-mock.ts`: `set_menu_state` is a no-op; the `menu` event never comes in the browser.
- `app/src/App.tsx`: `canStartNew` = a report is shown and no review is running or starting. `canCompare` = the same, and the comparison isn't loading. `nameBased` = the comparison report is on screen, so the check mark stays off while it loads and after a failed load. The UI calls `setMenuState` whenever one of the three changes. It handles both ids: the comparison item toggles between `compare("name-based")` and `compare("indexed")`. A click the UI ignores re-sends the state, because macOS has already flipped the mark. A failure to reach the app is written to the app log.
- `app/src/Shell.tsx`, `app/src/styles.css`: the segmented control and the "New review" link are gone from `StatusBar`, along with their CSS. The new `ComparisonBanner` sits between the status bar and the map or page, so it shows on every level. The toolbar row (rm-lkt7's `NextControl`) and the one-line status bar (rm-mgz2) are unchanged.

## What was checked

- `bazel test //...`: all 9 tests pass. `//app:ts` and `//app/src-tauri:reviewmap-app` build, and `scripts/build-app.sh` builds the bundle.
- **Real app** (bundle from `scripts/build-app.sh`, `REVIEWMAP_HOME` set to a scratch directory, review started with `reviewmap <repo> --base 0cd5916 --head 0e57fa4`):
  - The app log shows no menu error and no UI error. It shows `set_menu_state` reaching the app: both items disabled while the review ran (`new review false, comparison false`), then both enabled when it finished (`new review true, comparison true, comparison shown false`).
  - Quit, twice: 8 Bazel servers were running for the scratch home's output bases. After quitting, the log ended with `exiting: stopping the review's processes and the Bazel servers`, and no Bazel server or app process was left within 2–3 s. Quit was sent as the standard quit Apple Event (`osascript … to quit`). That runs the same `terminate:` as the predefined Quit menu item, but the menu item itself wasn't clicked.
- **Dev preview** (`REVIEWMAP_REPORT=<report> bazel run //app:dev`, report written by the bundle's `reviewmap --report`): the page loads with no console errors. The status bar shows only the analysis state and the coverage chip. The `menu` event was fired through the mocked event bus, and the `set_menu_state` calls were recorded:
  - `compare-name-based` showed the banner and sent `nameBased: true`.
  - The banner was visible on the review item (key j) and on the interface view (Escape).
  - "Back to indexed" hid the banner and sent `nameBased: false`.
  - Turning the comparison on again (cached) and off again from the menu worked.
  - `new-review` returned to the start screen and disabled both items.
  - With `name_based_report` made to fail: the item was disabled while loading, then re-enabled and left unchecked. The status bar showed "Stopped: <error>", as before.

## Checked by hand in the app

My request to control the app window with computer use was declined, so the user checked the native menu by hand on 2026-11-17. The bundle was the one from `scripts/build-app.sh`, with `REVIEWMAP_HOME=/tmp/rm-kifb-home`, reviewing `--base 0cd5916 --head 0e57fa4`. The user reported that everything works as expected: the File and View items, ⌘N, the check mark, the disabled look while running, the banner with "Back to indexed", and copy and paste. The app log of that run agrees:
- both items were disabled while the review ran and enabled when it finished;
- the comparison item was disabled while the comparison loaded, then the comparison report was shown;
- the comparison was turned off, on from the cache and off again;
- New Review disabled both items and returned to the start screen, and a second review ran from there;
- after Quit, the log records the shutdown and no Bazel server for that home was left running.
