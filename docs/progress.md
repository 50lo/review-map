# Progress

Milestones from the prototype brief. Each one is usable on a real PR before the next starts.

| # | Milestone | Status |
| --- | --- | --- |
| 1 | Analyzer core: tree export, SwiftSyntax parsing, entities and change kinds, components, name-based edges, JSON output | Done |
| 2 | Component map: level 1 of the viewer, reading the JSON | Done |
| 3 | Interface and implementation views: levels 2 and 3, navigation, Open in Xcode | Done |
| 4 | Regions and context: deterministic risk scoring and context collection | Not started |
| 5 | LLM annotator: ranking, summaries, removal candidates, cache, ranking toggle | Not started |
| 6 | Index mode: IndexStoreDB resolution, only if name-based edges prove too noisy | Not started |

## Milestone 1 notes

- Verified with the fixture tests and on 5 IceCubesApp PRs and 3 NetNewsWire commits (2 to 4 seconds each). Not yet run on macOS with Xcode or on the target app.
- The brief's done criterion, the JSON for five real PRs from the target repo looking right on manual inspection, still needs the target repo.

## Milestone 2 notes

- The viewer is a Vite app in `viewer/`. `reviewmap … --view` and `reviewmap view` start it on a model.
- Start here uses an interim ranking from contract flags, because `regions` is empty until milestone 4. It switches to regions automatically once the analyzer emits them.
- Clicking a component focuses it and shows its changed entities in the side panel. Milestone 3 adds level 2 behind a second tap.
- Checked in Chromium on desktop and phone widths, in light and dark mode, against the fixture and IceCubesApp. Not yet used on the target app.

## Milestone 3 notes

- Tapping a component on the map focuses it, as before. Tapping it again, or the "Open interface view" button in the side panel, opens level 2. A single tap that jumped straight to level 2 would lose the map's focus view.
- Level 2 lists interface changes grouped by kind, with changed signature tokens highlighted, the base signature behind a "base" toggle, contract flag chips, and Used by and Depends on lists. Internal changes are one line each, and cosmetic, test, and generated changes sit behind a count.
- Level 3 shows the entity's head code with Swift highlighting (Shiki). Until milestone 4 adds review regions, it marks the lines that changed inside the entity (ignoring indentation) and shows removed lines as collapsed markers. Unchanged code folds. Previous and Next step through the component's entities in level 2 order.
- Callers lead to their own entity when it changed, or to the line in an unchanged file. Changed type names and an entity's dependencies are clickable in code.
- The local server reads file contents with `git show` at the base and head commits, so the working copy doesn't need to be on either ref. Open in Xcode runs `xed --line` on the working copy file, and only on macOS.
- `build:single` embeds the source files the entities and their callers live in (8 MB cap by default).
- Not done yet from the brief's "across all levels": reviewed checkboxes, next/previous region shortcuts, and notes. Shortcuts need regions (milestone 4).
- Checked in Chromium at desktop and phone widths, in light and dark mode, on IceCubesApp. Open in Xcode not yet tried on a Mac.
