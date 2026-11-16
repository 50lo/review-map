---
# rm-ezdq
title: Make notes export reachable from anywhere and offer it when the review is done
status: completed
type: task
priority: normal
tags:
    - ui
created_at: 2026-11-16T11:24:42Z
updated_at: 2026-11-16T20:18:25Z
parent: rm-w7ge
---

## What

Make exporting review notes reachable from anywhere in the Review Map app (Tauri 2 app, React UI in `app/src/`), and offer it at the moment the review is finished.

Today the only export is in the Overview sidebar: `NotesSection` in `app/src/Sidebar.tsx` lists the notes (each a link back to its region) with two buttons, "Copy as Markdown" (clipboard) and "Download .md" (an `<a download="review-notes.md">` blob link). The Markdown comes from `notesMarkdown(notes)` in `app/src/review.ts`. The Overview sidebar is shown only when nothing is selected, and NOTES sits below Structural review, Start here and Progress. So after finishing a review on a review item page, the reviewer has to go back to the map, clear the selection and scroll the sidebar to find the export. This was reported by the user on 2026-11-16 from a finished review (15 of 15 review items reviewed, 1 note).

Add three ways in:

1. **Notes button in the toolbar, at every level.** In the toolbar row of `App.tsx` (the row with back/forward and the breadcrumbs, `nav.crumbs`, around line 359), on the right side, show a button "Notes N" when there is at least one note (N = `Object.keys(useReview().notes).length`); hide it when there are none. Clicking it opens a popover anchored to the button with:
   - the notes in file order (same order as `notesMarkdown`), each showing the review item label, `file:line` and the note text, and each clickable to open its region, exactly as `NotesSection` does today (`setFocus` to the review item and region, or to the location when the region is gone);
   - the two actions "Copy as Markdown" and "Download .md", with the same output as today.
   The popover closes on Escape, on a click outside it, and after following a note.
2. **Finish prompt.** When every review item to review is marked reviewed (the same count as the sidebar's Progress, `done === toReview.length` in `Sidebar.tsx`), show next to the toolbar's progress indicator "All N reviewed" and a button "Copy notes" when there are notes, or the text "No notes" when there are none. Task rm-lkt7 adds that progress indicator and the "All N reviewed" state; this task adds the notes action to it.
3. **Native menu items.** File → "Export Notes…" (⌘E) and Edit → "Copy Notes as Markdown" (⇧⌘C), both disabled when there are no notes or no review is open. Task rm-kifb builds the native menu (menu built in `setup` in `app/src-tauri/src/lib.rs`, clicks emitted as a `menu` event with payload `{ "id": string }`, enabled state set through a `set_menu_state` command; `onMenu` and `setMenuState` in `app/src/backend.ts`). Extend that contract with ids `export-notes` and `copy-notes` and a `hasNotes: boolean` field in `set_menu_state`'s argument.

Move the export logic out of `NotesSection` into one shared module (for example `app/src/notesExport.ts` with `copyNotes(notes): Promise<boolean>` and `saveNotes(notes): Promise<void>`), and use it from the sidebar, the popover, the finish prompt and the menu. Keep the sidebar's NOTES section.

"Download .md" must actually save a file inside the Tauri app window, not only in a browser. Check whether the `<a download>` blob link works in the app's WKWebView. If it doesn't, save with the system save dialog instead (`@tauri-apps/plugin-dialog` `save`, already a dependency and used by `backend.ts` for the folder picker, plus a small Rust command or the fs plugin to write the file), defaulting the file name to `review-notes.md`.

## Why

Exporting notes is the last step of every review: the notes are pasted into the real code review. Hiding the only export behind "go back to the map, deselect, scroll" makes the end of every review slower and easy to miss. A reviewer who doesn't find it may lose notes or retype them.

## Where

- `app/src/App.tsx`: toolbar row (`nav.crumbs`), the right-hand area that rm-lkt7 also uses; menu event handling (from rm-kifb).
- `app/src/Sidebar.tsx`: `NotesSection` (export logic to move into the shared module; section stays).
- `app/src/review.ts`: `notesMarkdown`, `useReview` (unchanged contract).
- New: `app/src/notesExport.ts` (or similar) and a popover component.
- `app/src/backend.ts` and `app/src-tauri/src/lib.rs`: menu ids and `set_menu_state` field (on top of rm-kifb), and a save command if the blob download doesn't work in the app.
- Styles in the app's CSS next to the existing toolbar styles.

## Acceptance criteria

- [x] With at least one note, a "Notes N" button is visible in the toolbar on the map level (with and without a selection) and on a review item page. With no notes it is not shown.
- [x] The popover lists every note in file order; clicking one opens its region (or its location when the region no longer exists) and closes the popover; Escape and a click outside close it.
- [x] "Copy as Markdown" puts exactly `notesMarkdown(notes)` on the clipboard and says "Copied"; "Download .md" saves `review-notes.md` with the same content from inside the Tauri app window (checked in the real app, not only in `bazel run //app:dev`).
- [x] When every review item is reviewed, the toolbar shows "All N reviewed" with "Copy notes" (with notes) or "No notes" (without).
- [x] File → Export Notes… (⌘E) and Edit → Copy Notes as Markdown (⇧⌘C) do the same as the two buttons and are disabled without notes or without an open review.
- [x] The sidebar's NOTES section still works and uses the shared export module.
- [x] Vitest tests cover: the button's visibility by note count, the popover's order and navigation target, the finish prompt's three states (not done / done with notes / done without notes), and that every entry point exports the same Markdown. `bazel test //app/...` passes.

## Dependencies and constraints

- Part 2 builds on rm-lkt7 (toolbar progress indicator and "All N reviewed" state) and part 3 on rm-kifb (native menu and its event contract). Part 1 does not depend on either and can ship first; if rm-lkt7 isn't done yet, place the Notes button where rm-lkt7's control will go, so they sit side by side.
- Notes and reviewed marks are saved per review by `app/src/review.ts`; this task only reads them. Don't change `Note`, `ReviewState` or `notesMarkdown`'s output.
- Run `statute show` on the files you touch before changing them (see `AGENTS.md`); no CORE rule is expected to cover this UI.
- Build and test with Bazelisk (`docs/rebuild-build.md`).


## Summary of Changes

- **Shared export, `app/src/notesExport.ts` (new).** Every entry point goes through it, so all of them export `notesMarkdown(notes)` unchanged.
  - `sortedNotes(notes)`: notes in file order, the order `notesMarkdown` writes them in.
  - `noteTarget(regions, regionId, note): Focus`: the region on its review item's page, or the code location when the region is gone.
  - `noteLocation(note)`: `file:line` or `file:start-end`.
  - `copyNotes(notes): Promise<boolean>`: false on failure.
  - `saveNotes(notes): Promise<"saved" | "dismissed" | "failed">`. Failures go to the app log.
  - `notesMenuAction(id, notes)`: runs `export-notes` or `copy-notes`, and returns null for any other menu id.
- **Components, `app/src/Notes.tsx` (new).** They take the notes as props.
  - `NotesList`: the list, each note a link.
  - `NotesActions`: "Copy as Markdown" and "Download .md". Each shows "Copied" / "Saved" (or "Couldn't copy" / "Couldn't save") for 2 s.
  - `NotesButton`: the toolbar's "Notes N" button and its popover. It is hidden without notes. The popover shows label, `file:line` and text for each note. It closes on Escape (caught in the capture phase, so the focus doesn't also move up a level), on a mousedown outside it, and after opening a note. The outside-click listener also uses the capture phase: React Flow's zoom handler stops a mousedown on the map from reaching the document.
  - `ReviewProgress`: "X/Y reviewed", or "All Y reviewed" plus "Copy notes" (primary button) or "No notes".
- **`app/src/App.tsx`.**
  - The toolbar's right end is now a `toolbar-end` group: the Notes button, then rm-lkt7's `NextControl`.
  - `NextControl` renders `ReviewProgress` in both of its branches (map and review item stepper).
  - The menu state has `hasNotes = !!report && <note count> > 0`. Notes stay loaded after New Review…, so the start screen must not enable the items.
  - `onMenu` runs the two new ids through `notesMenuAction` when `hasNotes` is true. Otherwise it re-sends the state, as before.
- **`app/src/Sidebar.tsx`.** `NotesSection` keeps its place and look, and uses `NotesList` and `NotesActions`.
- **Download in the real app.**
  - The `<a download>` blob link does nothing in the app. wry 0.57's `navigation_policy` cancels any navigation WebKit marks `shouldPerformDownload` unless a download handler is set (`src/wkwebview/navigation.rs`), and the app sets none (`on_download` isn't called anywhere in `app/src-tauri`).
  - The new async command `export_notes(markdown: String) -> Result<Option<String>, String>` in `app/src-tauri/src/lib.rs` saves instead. It opens the system save dialog through `tauri_plugin_dialog::DialogExt`, already a dependency: title "Export Notes", file name `review-notes.md`, Markdown filter. It writes the file and returns the path, or None when dismissed.
  - The save path never comes from the page: the dialog picks it.
  - It is async because the dialog runs on the main thread and the command waits for it.
- **Copy through the app.**
  - New command `copy_text(text: String) -> Result<(), String>` pipes the text to `/usr/bin/pbcopy` with `LANG=en_US.UTF-8` and `LC_CTYPE=UTF-8`. An app opened from Finder has no locale, and without those pbcopy mangles non-ASCII text such as the `·` that `notesMarkdown` writes.
  - The web view's `navigator.clipboard` works only during a click in the page. Edit → Copy Notes as Markdown is a click in the menu bar.
  - No new crates or npm packages.
- **Menu, `app/src-tauri/src/menu.rs`.**
  - File → "Export Notes…" (⌘E, id `export-notes`), between New Review… and Close Window, with separators.
  - Edit → "Copy Notes as Markdown" (⇧⌘C, id `copy-notes`), after Select All, with a separator.
  - Both start disabled. Clicks emit the existing `menu` event with `{ "id": string }`.
  - `MenuState` gains `has_notes` (`hasNotes` in JSON), which enables both items. The `set_menu_state` log line now ends with `notes true|false`.
- **`app/src/backend.ts`.** `MenuState.hasNotes`, plus `copyText(text)` and `exportNotes(markdown)`.
- **`app/src/dev-mock.ts`.** `copy_text` uses `navigator.clipboard`. `export_notes` downloads through a blob link, since the browser has no save dialog.
- **`app/src/styles.css`.** Styles for the Notes button, popover and finish prompt. The Next button's `max-width` dropped from 200 px to 160 px, so the Notes button fits beside it on one row at 1100 px.
- **`app/BUILD.bazel`.** The test glob also picks up `*.test.tsx`.
- **Tests.** `app/src/notes.test.tsx` (13 Vitest tests, rendered with `react-dom/server`):
  - the button is hidden at 0 notes and shows the count;
  - the popover lists the notes in file order, with locations and both actions;
  - `sortedNotes` matches `notesMarkdown`'s order;
  - a note's target is its region, or its location when the region is gone;
  - the finish prompt's states: not done, done with notes, done without notes, and nothing to review;
  - copy, save and both menu ids send exactly `notesMarkdown(notes)`, and other menu ids do nothing;
  - a dismissed dialog and a failed copy are reported.

  The components' click handlers aren't clicked in Vitest (no DOM). They were clicked in the dev preview and the real app (below).

## What was checked

- `bazel test //...`: all 9 tests pass, including `//app:test` (153 Vitest tests, 13 of them new) and `//app:ts_typecheck_test`. `scripts/build-app.sh` builds the bundle.
- **Real app.**
  - Setup: the bundle from `scripts/build-app.sh`, `REVIEWMAP_HOME` set to a scratch directory, and a saved review state with 2 notes, one of them non-ASCII, written before the start. The review was started with `reviewmap <worktree> --base 0cd5916 --head 0e57fa4` and driven with computer use (access granted this time).
  - Log: the menu state went `notes false` before the report, then `notes true`.
  - Toolbar: "Notes 2" on the map. The popover listed both notes in file order.
  - "Download .md" in the popover opened the save dialog: title "Export Notes", name `review-notes.md`. Saving showed "Saved", and the file matched `notesMarkdown` byte for byte (`cmp`).
  - "Copy as Markdown" showed "Copied", and the clipboard matched byte for byte.
  - Clicking a note opened Cart.total() at its region and closed the popover. On that page, Escape closed the popover and stayed on the page.
  - ⇧⌘C: the clipboard matched byte for byte (log: `copied 303 bytes`).
  - ⌘E: the save dialog opened, and the saved file matched (log: `exported notes (303 bytes)`).
  - The menus show File → Export Notes… ⌘E and Edit → Copy Notes as Markdown ⇧⌘C.
  - After ⌘N (start screen), File → Export Notes… was drawn disabled, and the log shows `notes false`.
  - Quit logged the shutdown and left no app process.
  - The test files were moved out of `~/Downloads` afterwards.
- **Dev preview** (`REVIEWMAP_REPORT=<report> bazel run //app:dev`, 4 notes seeded through the mock's storage, one of them on a region id that doesn't exist; window 1100 × 750):
  - "Notes 4" shows on the map with no selection, with a component selected, on a review item page and on a code location page. It is hidden with 0 notes.
  - The popover is in file order. A note opens its region. The note without a region opens `#l=head:10:app/src/App.tsx`.
  - Escape, a click on the map, and following a note each close the popover.
  - The popover's and the sidebar's Copy and Download each exported exactly `notesMarkdown(notes)`.
  - The `menu` event with `copy-notes` and `export-notes` (sent through the mocked event bus) did the same.
  - Finish prompt on the map and in the review item stepper: "All 1306 reviewed" + "Copy notes", which says "Copied" and copies the same Markdown. With no notes: "All 1306 reviewed" + "No notes", the Notes button is hidden and `set_menu_state` sends `hasNotes: false`.
- **Toolbar width at 1100 px.** The toolbar stays on one row in these cases:
  - map with and without a selection, "Changed components", the longest Next name in the report;
  - review item page with the stepper, done and not done;
  - all reviewed with "Copy notes".

  With "Whole system" and the "Expand groups" link it wraps to two rows. It did so before this task too (measured without notes: 81 px tall).

Screenshots are in the side-session notes folder, `rm-ezdq-screenshots/`.

## Not checked

- In the real app: the finish prompt. Marking all 1306 review items by hand wasn't practical; it was checked in the dev preview.
- In the real app: the Notes button with a component selected, and the "region is gone" note. Both were checked in the dev preview.
- In the real app: the Edit → Copy Notes as Markdown item drawn disabled. The capture of the Edit menu came out blank after ⌘N. The log shows `notes false`, and the item shares that flag with File → Export Notes…, which was seen disabled.
- In the real app: an open review with zero notes. Only the dev preview's `set_menu_state` shows `hasNotes: false` there.
- Clicking the two menu items with the mouse. The real app was driven with ⌘E and ⇧⌘C, which invoke the same menu items.
- Copy and paste through the predefined Edit items, after Copy Notes as Markdown was added to the Edit menu.

## Follow-up

The status bar's coverage popover (`CoverageChip` in `app/src/Shell.tsx`, from rm-mgz2) listens for a bubbling `mousedown` on the document. React Flow's zoom handler stops a mousedown on the map, so a click on the map doesn't close that popover. The Notes popover avoids this with a capture-phase listener.
