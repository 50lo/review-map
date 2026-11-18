---
# rm-b5d2
title: Make the map legend reachable from the map, and dimmed text readable
status: todo
type: task
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T09:57:22Z
parent: rm-w7ge
---

## What

Two readability fixes on the map:

1. **A legend reachable from the map.** The legend (added, removed, changed and unchanged edge colours, arrow direction, "stronger tint means a larger change") is only in the Overview sidebar (`Overview` in `app/src/Sidebar.tsx`). It disappears as soon as anything is selected. Add a "?" button to the map's zoom controls (`<Controls>` in `app/src/MapView.tsx`; React Flow's `ControlButton` fits there). It toggles a small popover with a complete legend:
   - **Edges:** added (green), removed (red, dashed), changed (orange, different symbols referenced), unchanged (grey). Arrows point from the code that uses to the code it uses. Line weight grows with the number of references.
   - **Nodes:**
     - a green border with a "new" tag means an added component
     - a red dashed border with a "removed" tag means a removed one
     - external package pills show "new <version>", "removed" or "<from> → <to>"
     - background tint strength is the change score
     - "N changed" and "N interface" badges count changed review items and interface changes
     - the bar at the bottom is review progress
     - a stacked card is a collapsed group, and "▸ N" expands it
   - **Findings:** the badge colour is the top severity (high, medium, low).
   - **Selection:** everything not related to the selection is dimmed.

   Keep the Overview's legend, or replace it with the same component, so the two never disagree.
2. **Readable dimmed text.** Dimmed node text uses `--dim-fg: color-mix(in srgb, var(--muted) 45%, var(--bg))` (`app/src/styles.css`, around line 22). In dark mode, labels such as "197 changed" or "18 changed · 1 interface" on dimmed nodes are barely readable (screenshot of 2026-11-16). The reviewer still needs to read dimmed nodes to decide where to click next. Raise the contrast of dimmed text while keeping it clearly weaker than normal text.

## Why

The map's meaning is carried by colour, dash style, tint and small badges. Without the legend in reach, a new reviewer has to clear the selection to look it up, or guess. Dimmed nodes that can't be read force the reviewer to clear the selection just to read names.

## Where

- `app/src/MapView.tsx`: `<Controls showInteractive={false} />`.
- `app/src/Sidebar.tsx`: the Overview's "Legend" section. Move it into a shared component, e.g. `app/src/Legend.tsx`, used by both.
- `app/src/styles.css`: `--dim-fg` in the light and dark theme blocks, and `.node.dim` rules.

## Acceptance criteria

- [ ] A "?" control next to the zoom buttons opens and closes the legend on every map state, with or without a selection. Escape or a click elsewhere closes it.
- [ ] The legend covers every mark listed above. The Overview's legend uses the same component, or is removed.
- [ ] Dimmed node text has a contrast ratio of at least 3:1 against the map background in both light and dark mode. Undimmed text stays clearly stronger. Record both ratios in this bean.
- [ ] Screenshots before and after, light and dark, attached to this bean. Use the app or `REVIEWMAP_REPORT=<report.json> bazel run //app:dev`; see `docs/rebuild-build.md`.
- [ ] `bazel test //app:test` passes.

## Dependencies and constraints

- The task "Dim every mark outside the map selection" (rm-6cla) in this epic also edits the dim CSS. Do that one first, or both together, so the contrast is measured on the final dimmed style.
- Epic: UI improvements (rm-w7ge).
