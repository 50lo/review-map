# Progress

Milestones from the prototype brief. Each one is usable on a real PR before the next starts.

| # | Milestone | Status |
| --- | --- | --- |
| 1 | Analyzer core: tree export, SwiftSyntax parsing, entities and change kinds, components, name-based edges, JSON output | Done |
| 2 | Component map: level 1 of the viewer, reading the JSON | Done |
| 3 | Interface and implementation views: levels 2 and 3, navigation, Open in Xcode | Done |
| 4 | Regions and context: deterministic risk scoring and context collection | Done |
| 5 | LLM annotator: ranking, summaries, removal candidates, cache, ranking toggle | Done |
| 6 | Index mode: IndexStoreDB resolution, only if name-based edges prove too noisy | Done |

## Milestone 1 notes

- Verified with the fixture tests and on 5 IceCubesApp PRs and 3 NetNewsWire commits (2 to 4 seconds each). Not yet run on macOS with Xcode or on the target app.
- The brief's done criterion, the JSON for five real PRs from the target repo looking right on manual inspection, still needs the target repo.

## Milestone 2 notes

- The viewer is a Vite app in `viewer/`. `reviewmap … --view` and `reviewmap view` start it on a model.
- Start here ranked by contract flags until milestone 4. A model without regions still ranks that way.
- Clicking a component focuses it and shows its changed entities in the side panel. Milestone 3 adds level 2 behind a second tap.
- Checked in Chromium on desktop and phone widths, in light and dark mode, against the fixture and IceCubesApp. Not yet used on the target app.

## Milestone 3 notes

- Tapping a component on the map focuses it, as before. Tapping it again, or the "Open interface view" button in the side panel, opens level 2. A single tap that jumped straight to level 2 would lose the map's focus view.
- Level 2 lists interface changes grouped by kind, with changed signature tokens highlighted, the base signature behind a "base" toggle, contract flag chips, and Used by and Depends on lists. Internal changes are one line each, and cosmetic, test, and generated changes sit behind a count.
- Level 3 shows the entity's head code with Swift highlighting (Shiki). Milestone 4 replaced its changed-line marks with review and context regions. Unchanged code folds. Previous and Next step through the component's entities in level 2 order.
- Callers lead to their own entity when it changed, or to the line in an unchanged file. Changed type names and an entity's dependencies are clickable in code.
- The local server reads file contents with `git show` at the base and head commits, so the working copy doesn't need to be on either ref. Open in Xcode runs `xed --line` on the working copy file, and only on macOS.
- `build:single` embeds the source files the entities and their callers live in (8 MB cap by default).
- Checked in Chromium at desktop and phone widths, in light and dark mode, on IceCubesApp. Open in Xcode not yet tried on a Mac.

## Milestone 4 notes

- The analyzer emits review, removed, and context regions. Risk follows the brief's table, plus these additions: a changed interface signature and a removed interface declaration are medium, usage from other components adds up to 0.2, tasks and locks are medium while isolation annotations stay high, and control flow in SwiftUI view code counts half of medium so layout-heavy `body` changes don't dominate. Weights are not tuned yet.
- Region reasons show in a label row above each region rather than a side gutter, because a gutter doesn't fit at phone width.
- Context snippets are collapsed to one-line labels by default (the brief's "related items stay quiet"). Whether they help or clutter is still open.
- Removed lines inside a block that also adds lines are part of the review region (their removed checks count), and the viewer places them as markers by comparing base and head. Pure deletions are `removed` regions with an anchor.
- Start here groups regions by entity and folds members into their type, so one Codable type or enum doesn't fill the list. Each row opens its riskiest region.
- Reviewed checkboxes, notes with Markdown export, and region shortcuts (`j`/`k`, `]`/`[`) are in. With the local server they're saved next to the model; the single-file build uses browser storage, because it has no server to write a file.
- On IceCubesApp's last 40 commits: 248 review, 23 removed, and 366 context regions (222 callers, 73 state, 69 definitions, 2 conformers), 2.3 seconds. The top of the ranking is enum cases and Codable shapes on widely used interface types, then concurrency changes in view models.
- Checked in Chromium at phone and desktop widths, in light and dark mode, through the local server and the single-file build. Not yet run on macOS or on the target app.

## Milestone 5 notes

- The annotator runs the `claude` or `codex` CLI, not the API, so it uses the local login. It runs by default and `--no-llm` skips it. `reviewmap annotate` re-runs it on an existing model.
- `reviewmap` with no arguments reviews the current branch of the current directory against `main` and opens the viewer, the command used almost every time. `analyze`, `annotate`, and `view` keep one step each.
- Models go to `~/.reviewmap/models/<repo>/<head>/` by default, so running inside the target repo writes nothing there and each branch keeps its own reviewed marks and notes. Two repos with the same folder name share a directory.
- In use with the `claude` CLI on Anton's repos. The `codex exec` path (`--output-last-message`, prompt on stdin with `-`) has not run yet. Tests and demos use `scripts/fake-llm.sh`, which fills the reply template with canned values.
- Removal candidates are tagged on review regions, since every changed entity has at least one; a speculative abstraction is tagged on its declaration region.
- The ranking toggle switches the whole LLM layer, not only the ranking: with it off the viewer shows no LLM notes, summaries, pruning, or removal candidates, so the tool can be compared with and without the LLM.
- Entity and component summaries are always shown when the LLM layer is on, because they were opened almost every time. Region notes and removal notes stay on demand. Context the LLM leaves out folds into a count after the kept snippets.
- Test components, test and generated code, and cosmetic changes are not sent to the LLM.
- On IceCubesApp's last 40 commits with the fake: 23 batches, the largest prompt about 79,000 characters, 13 seconds in all.

## Milestone 6 notes

- Started because name-based edges were too noisy in one of the target repos.
- `--index` (or `index.enabled` in `reviewmap.yml`) builds base and head once per commit and reads their index stores with IndexStoreDB. The stores are cached in `~/.reviewmap/index`, so the base of several branches is built once.
- Index mode drives edges, `usedBy`, `dependsOn`, caller context, and definition context. Conformers and overrides still come from inheritance clauses.
- If either side doesn't build, both sides fall back to name matching with a warning, because comparing an index-resolved side with a name-resolved one would show differences that aren't in the change.
- Edge references keep the referenced top-level declaration as their symbol, so an edge changes when the set of used types changes, as in name mode, but now exactly.
- Without `--index-project`, the workspace or project is searched for anywhere in the repo, preferring ones under the directory reviewmap runs from; `--index-project` may be relative to the current directory or the repo root, or absolute.
- Tested with `swift build` on Linux against `Fixtures/indexed`. The xcodebuild path (scheme detection, the simulator build, `Index.noindex/DataStore`) has not run yet.
- The overview says whether references were resolved exactly or matched by name.
- A generated Xcode project (rules_xcodeproj, XcodeGen, Tuist) isn't in git, so it isn't in the commits being built. For Bazel repos, index mode builds the `top_level_targets` of the rules_xcodeproj rule with Bazel and reads rules_swift's global index store; index paths relative to Bazel's execution root are mapped back to repo paths. The Bazel workspace may be a subdirectory (such as `ios/`), found from the current directory up or, failing that, below it. Tested with a stand-in `bazel`; the first run with real Bazel and rules_swift is on Anton's repo.

## Remaining checks

- Milestone 1's done criterion: the change model of five real PRs from the target app looks right on manual inspection. So far only IceCubesApp and NetNewsWire have been checked.
- Index mode with real Bazel and rules_swift on the target repo: the build in a fresh output base, and whether the index covers the app's files (no large `index-partial` warning).

## Findings

From a few days of use on real PRs.

- Indexing is essential. Matching by name creates false links, and the false links make the map confusing.
- Indexing by building the whole project is too slow. A clean build of one of the target projects takes about 20 minutes.
- LLM suggestions on individual fragments add little. They rarely surface issues the automated review agents on CI didn't already find. Structural reviews, over the shape of the change rather than single fragments, are worth exploring.
- The most valuable parts are the visual map of the change, seeing the code behind each arrow and block, and opening changed fragments in the IDE quickly.

## Open questions

- Is folder-based grouping good enough, or should an LLM propose the component grouping?
- Is the component map the right entry point, or does Start here get used more?
- How should removed code be shown without falling back to a diff?
- Do inline context snippets help, or do they clutter the view?
- How should large SwiftUI `body` changes that are mostly layout be handled, so they don't dominate the ranking?
- How should changes in non-Swift files be shown: storyboards, asset catalogs, plists, and the project file?
