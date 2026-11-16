---
# rm-6cla
title: Dim every mark outside the map selection
status: completed
type: bug
priority: normal
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T10:17:09Z
parent: rm-w7ge
---

## What

When the reviewer selects a node or edge on the map, everything outside the selection is drawn in muted colours. Some marks don't get muted, so the selection stands out less than the nodes around it. Make dimming apply to every mark on a node and edge.

**Observed** (screenshot of 2026-11-16, external package `@tauri-apps/cli` selected), on the dimmed nodes:

- External package nodes keep their bright borders: green for added, orange for bumped, red dashed for removed.
- The "1 finding" badges keep their filled orange or grey background.
- The language icons (Swift, TS) stay bright white.
- Edge labels such as "1 finding" on dimmed edges keep their severity colour.

The selected node has only a blue outline, so the eye goes to the bright orange badges instead.

**Expected:** the selected node and the nodes and edges related to it (`related()` in `app/src/graph.ts`) keep their full colours. Everything else uses the muted colours (`--dim-fg`, `--dim-line`, `--edge-dim` in `app/src/styles.css`): status borders, finding badges, tags, layer labels, language badges, progress bars and edge labels. A dimmed node keeps its shape and border style (dashed stays dashed), so it is still recognisable.

**Cause** (checked in the code on 2026-11-16):

- The dimming rules are `.node.dim`, `.group.dim` and `.node.dim .badge` (around `app/src/styles.css:456`). Two sets of colour rules have the same specificity and come later in the file, so they win:
  - `.badge.finding-badge.sev-high` / `.sev-medium` (around line 1465)
  - `.node.ext-added` / `-bumped` / `-removed` (around line 623)
- Language badges (`app/src/LanguageBadges.tsx`) have no dimmed style.
- Edges get no dim class. `MapView.tsx` mutes an edge's stroke with an inline style. The label colour comes from `.react-flow__edge.edge-finding.sev-*` and ignores dimming.

**Steps to reproduce:**

1. Open a review whose map has external package changes and findings. One example is base `0cd5916` (`rebuild-tauri-app-and-indexing`) against head `0e57fa4` in this repository.
2. Click one node.
3. Look at the other nodes.

## Why

Dimming exists to make the selection and what it touches stand out. Right now it does the opposite for exactly the nodes that carry the strongest colours. The reviewer can't tell at a glance what is selected or related.

## Where

- `app/src/styles.css`: the dim rules and the rules that override them.
- `app/src/MapView.tsx`: `edges` memo. Add a class such as `edge-dim` when an edge is outside `rel`, so CSS can mute its label. Nodes already get `dim` in `data.dim`.
- `app/src/LanguageBadges.tsx`: if its icons need a dim variant.

## Acceptance criteria

- [x] With a node selected, no node or edge outside the selection and its related set shows a saturated colour: not the added, removed or changed colour, not a severity colour, not a white or bright language icon.
- [x] The selected and related nodes and edges look exactly as they do without a selection.
- [x] Removed nodes and edges stay dashed when dimmed.
- [x] Checked in light and dark mode, with screenshots before and after of the same map and selection. Use the app or `REVIEWMAP_REPORT=<report.json> bazel run //app:dev`; see `docs/rebuild-build.md`.
- [x] `bazel test //app:test` passes.

## Dependencies and constraints

- `MapView.tsx` explains why dimming uses muted colours, not opacity: on a large map, a selection that made hundreds of elements translucent left parts of the page unpainted. Keep using colours, not opacity.
- The readability of dimmed text is a separate task in the same epic ("Make the map legend reachable from the map, and dimmed text readable", rm-b5d2). It also edits `--dim-fg`. Do this task first, or both together.
- Epic: UI improvements (rm-w7ge).

## Summary of Changes

- `app/src/styles.css`: every rule that colours a mark on a node or edge now has a dimmed counterpart with one class more, so it wins wherever it sits in the file. Dimmed status borders (`.node.dim.st-*`, `.group.dim.st-*`, `.node.dim.ext-*`) take `--dim-line`. Only the colour changes, so dashed borders stay dashed; the ineffective `border-style: solid` on `.node.dim` / `.group.dim` is gone. Dimmed finding badges on nodes and groups are drawn as an outline: `--bg` fill, `--dim-fg` text, a `--dim-line` inset ring. The fill keeps the node's top border from running through a corner badge. A dimmed language icon is its silhouette in `--dim-fg`, drawn with `mask` instead of the image on a white tile. Finding labels on dimmed edges use `--dim-fg` on a `--bg` background.
- `app/src/MapView.tsx`: edges outside `rel` get the class `edge-dim`. The stroke is still muted inline, with colours, not opacity.
- `app/src/LanguageBadges.tsx`: each icon sets `--icon: url("…")` for the mask. It's quoted because Vite inlines the SVGs as data URIs.
- Checked in the dev preview with the 0cd5916..0e57fa4 report, selecting `@tauri-apps/cli` and `react`, in light and dark mode, with before and after screenshots at the same viewport. A script found no saturated colour on any visible mark of a dimmed node or edge. The properties this change touches are identical on lit elements with and without a selection. `--dim-fg` is unchanged (rm-b5d2).
