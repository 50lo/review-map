# Progress

Milestones from the prototype brief. Each one is usable on a real PR before the next starts.

| # | Milestone | Status |
| --- | --- | --- |
| 1 | Analyzer core: tree export, SwiftSyntax parsing, entities and change kinds, components, name-based edges, JSON output | Done |
| 2 | Component map: level 1 of the viewer, reading the JSON | Done |
| 3 | Interface and implementation views: levels 2 and 3, navigation, Open in Xcode | Not started |
| 4 | Regions and context: deterministic risk scoring and context collection | Not started |
| 5 | LLM annotator: ranking, summaries, removal candidates, cache, ranking toggle | Not started |
| 6 | Index mode: IndexStoreDB resolution, only if name-based edges prove too noisy | Not started |

## Milestone 1 notes

- Verified with the fixture tests and on 5 IceCubesApp PRs and 3 NetNewsWire commits (2 to 4 seconds each). Not yet run on macOS with Xcode or on the target app.
- The brief's done criterion, the JSON for five real PRs from the target repo looking right on manual inspection, still needs the target repo.

## Milestone 2 notes

- The viewer is a Vite app in `viewer/`. `reviewmap … --view` and `reviewmap view` start it on a model.
- Start here uses an interim ranking from contract flags, because `regions` is empty until milestone 4. It switches to regions automatically once the analyzer emits them.
- Clicking a component focuses it and shows its changed entities in the side panel, instead of opening level 2, which is milestone 3.
- Checked in Chromium on desktop and phone widths, in light and dark mode, against the fixture and IceCubesApp. Not yet used on the target app.
