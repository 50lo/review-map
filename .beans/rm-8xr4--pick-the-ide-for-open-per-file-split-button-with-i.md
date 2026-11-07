---
# rm-8xr4
title: Pick the IDE for Open per file (split button with IDE dropdown)
status: todo
type: feature
created_at: 2026-11-07T21:30:17Z
updated_at: 2026-11-07T21:30:17Z
---

## What

Let the reviewer pick which IDE "Open" uses, per file, instead of always offering Xcode. Today the viewer offers "Open in Xcode" even for Kotlin or TypeScript files, which Xcode can't handle.

There are two Open controls in the viewer (both rendered by `OpenButton` in `viewer/src/Pages.tsx`):

1. **Header button** ("Open in Xcode", the non-compact `OpenButton`, used at `Pages.tsx` ~line 476 and ~673). Turn it into a split button: clicking the title opens the current file/line in the selected IDE; a down-chevron on the right opens a dropdown to pick another IDE. The title reads "Open in <IDE>".
2. **Region header link** ("Xcode" next to "Note", the `compact` `OpenButton`, ~line 385). Keep its current look (plain link, no dropdown), but it shows and uses the same selected IDE, so changing the IDE in the header dropdown updates these links too.

Default IDE per file, by extension (use `languageOfPath` in `viewer/src/languages.ts`):
- Swift → Xcode
- Kotlin → Android Studio
- TypeScript → VS Code
- anything else → Zed

Picking an IDE in the dropdown overrides the default. Simplest reasonable behavior: the choice applies to files of the same language for the rest of the session (store it in viewer state / localStorage keyed by language), so other files still get their own language default.

## Why

Opening Kotlin files in Xcode fails or opens the wrong app; the reviewer has to switch editors by hand. Picking the IDE in the viewer removes that.

## Where / how it works today

- `viewer/server/repo.ts`: `Editor { name, args }`, `EDITOR_PRESETS` (xcode, vscode, cursor, zed, idea, webstorm, goland, rustrover; **no Android Studio yet**), `editorFrom()` picks one editor from `REVIEWMAP_EDITOR` (default Xcode on macOS), `openInEditor(editor, repo, file, line)` runs it with `execFile`.
- `viewer/vite.config.ts`: builds the single `editor` at server start; `POST /api/open?file=&line=` always uses it; exposes only its name to the client as `__REVIEWMAP_EDITOR__`.
- `viewer/src/source.ts`: `editorName()`, `canOpenInEditor()`, `openInEditor(file, line)` calling `/api/open`.
- `Sources/reviewmap/Viewer.swift`: `--editor` flag sets `REVIEWMAP_EDITOR`; `editorHelp` lists presets.

## Changes

- Add an `androidstudio` preset (macOS launcher `studio --line {line} {file}`; verify the command, fall back to `open -a "Android Studio" ...` if `studio` isn't on PATH).
- `/api/open` accepts an optional `editor=<preset key>` param; accept only keys in `EDITOR_PRESETS` (never an arbitrary command from the client). Without it, keep using the server's configured editor.
- Expose the list of available presets (key + name) to the client, e.g. via a `define` next to `__REVIEWMAP_EDITOR__` or a small `GET /api/editors`.
- `source.ts`: `openInEditor(file, line, editorKey)`, plus a helper for the default IDE of a path.
- `Pages.tsx`: split button + dropdown for the header `OpenButton`; compact link reads the shared selection. Share the selection through a small context or store so both update together.
- Decide how `--editor` / `REVIEWMAP_EDITOR` fits: if set explicitly, use it as the default for all files (it overrides the per-language defaults); if unset, use the per-language defaults above. Update `editorHelp` accordingly.

## Acceptance criteria

- [ ] Swift file: header shows "Open in Xcode", region links show "Xcode"; Kotlin → Android Studio; `.ts`/`.tsx` → VS Code; other files → Zed.
- [ ] Header button has a chevron that opens a dropdown of IDEs; clicking the title opens the file at the right line in the selected IDE.
- [ ] Changing the IDE in the dropdown updates the region-header links on the page without reload.
- [ ] Region-header links keep the current compact link design (no dropdown).
- [ ] `/api/open` rejects editor keys that aren't presets.
- [ ] Explicit `--editor` / `REVIEWMAP_EDITOR` still works.
- [ ] Unit tests for the default-IDE mapping and the `editor` param validation (next to the existing `editorFrom` tests in `viewer/src/graph.test.ts`); `npm test` passes.

## Constraints

- Open stays POST-only and limited to files inside the repo's working copy (existing `openInEditor` checks).
- Open stays hidden when the page isn't served by the local server (`canOpenInEditor`).
