# Progress

Milestones from the prototype brief. Each one is usable on a real PR before the next starts.

| # | Milestone | Status |
| --- | --- | --- |
| 1 | Analyzer core: tree export, SwiftSyntax parsing, entities and change kinds, components, name-based edges, JSON output | Done |
| 2 | Component map: level 1 of the viewer, reading the JSON | Not started |
| 3 | Interface and implementation views: levels 2 and 3, navigation, Open in Xcode | Not started |
| 4 | Regions and context: deterministic risk scoring and context collection | Not started |
| 5 | LLM annotator: ranking, summaries, removal candidates, cache, ranking toggle | Not started |
| 6 | Index mode: IndexStoreDB resolution, only if name-based edges prove too noisy | Not started |

## Milestone 1 notes

- Verified with the fixture tests and on 5 IceCubesApp PRs and 3 NetNewsWire commits (2 to 4 seconds each). Not yet run on macOS with Xcode or on the target app.
- The brief's done criterion, the JSON for five real PRs from the target repo looking right on manual inspection, still needs the target repo.
