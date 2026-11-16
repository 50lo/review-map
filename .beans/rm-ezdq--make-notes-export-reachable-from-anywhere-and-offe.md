---
# rm-ezdq
title: Make notes export reachable from anywhere and offer it when the review is done
status: todo
type: task
tags:
    - ui
created_at: 2026-11-16T11:24:42Z
updated_at: 2026-11-16T11:24:42Z
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

- With at least one note, a "Notes N" button is visible in the toolbar on the map level (with and without a selection) and on a review item page. With no notes it is not shown.
- The popover lists every note in file order; clicking one opens its region (or its location when the region no longer exists) and closes the popover; Escape and a click outside close it.
- "Copy as Markdown" puts exactly `notesMarkdown(notes)` on the clipboard and says "Copied"; "Download .md" saves `review-notes.md` with the same content from inside the Tauri app window (checked in the real app, not only in `bazel run //app:dev`).
- When every review item is reviewed, the toolbar shows "All N reviewed" with "Copy notes" (with notes) or "No notes" (without).
- File → Export Notes… (⌘E) and Edit → Copy Notes as Markdown (⇧⌘C) do the same as the two buttons and are disabled without notes or without an open review.
- The sidebar's NOTES section still works and uses the shared export module.
- Vitest tests cover: the button's visibility by note count, the popover's order and navigation target, the finish prompt's three states (not done / done with notes / done without notes), and that every entry point exports the same Markdown. `bazel test //app/...` passes.

## Dependencies and constraints

- Part 2 builds on rm-lkt7 (toolbar progress indicator and "All N reviewed" state) and part 3 on rm-kifb (native menu and its event contract). Part 1 does not depend on either and can ship first; if rm-lkt7 isn't done yet, place the Notes button where rm-lkt7's control will go, so they sit side by side.
- Notes and reviewed marks are saved per review by `app/src/review.ts`; this task only reads them. Don't change `Note`, `ReviewState` or `notesMarkdown`'s output.
- Run `statute show` on the files you touch before changing them (see `AGENTS.md`); no CORE rule is expected to cover this UI.
- Build and test with Bazelisk (`docs/rebuild-build.md`).
