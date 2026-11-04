# Progress

Steps from [plan.md](plan.md). Each one is usable on real PRs before the next starts.

| # | Step | Status |
| --- | --- | --- |
| 1 | Map: selection glitch, collapse and expand, editor command | Done; the glitch fix still needs a check on a large real model |
| 2 | Language-neutral core | Not started |
| 3 | TypeScript | Not started |
| 4 | Structural review | Not started |
| 5 | Faster Swift indexing | Not started |

## Step 1 notes

- **Selection glitch.** The map has no opacity left: dimmed nodes and edges, and unchanged edges, use colors mixed with the background, and the opacity transitions are gone. While an interface or code page is open, the map and the side panel under it are `visibility: hidden`, so they aren't painted and keep their viewport. React Flow renders only the elements in view (`onlyRenderVisibleElements`). The glitch didn't reproduce in headless Chromium, which has no GPU, so whether this fixes it is still to be seen on the model where it happened. If it doesn't, the next move is Cytoscape.js.
- With culling on, React Flow's `fitView` only saw the nodes it had already measured and zoomed in on them after a relayout. Nodes now carry their layout size, and the map fits to the layout's own bounds.
- **Collapse and expand.** A target split into folders collapses into one node, drawn as a stack with the number of components inside, and edges into it are bundled per pair of drawn nodes. A bundle takes the status its edges share, or changed when they differ. Groups start collapsed when more than 40 components are visible. Collapse state starts over when the scope or the test filter changes.
- A focus inside a collapsed group opens the group: a component or entity opens the groups around it, and an edge also opens its ends, since a group's own edge would otherwise be drawn inside a bundle. Selecting a collapsed group leaves it collapsed.
- A bundled edge is its own focus (`#b=<from>&t=<to>`). Its side panel lists the dependencies inside, and picking one opens the group.
- **Neighbors.** The default scope is unchanged: changed components and the other ends of changed edges. "Show N more neighbors" in a component's side panel adds its hidden neighbors on request; expansions start over with the scope.
- **Editor command.** `--editor` on `reviewmap` and `reviewmap view` (or `REVIEWMAP_EDITOR`) takes a preset (`xcode`, `vscode`, `cursor`, `zed`, `idea`, `webstorm`, `goland`, `rustrover`) or a command with `{file}` and `{line}`. The default stays Xcode on macOS; elsewhere the Open buttons are hidden until an editor is set. The buttons are named after the editor.
- Checked in Chromium at desktop and phone widths, in light and dark mode, on the fixture and on a synthetic model with 360 components and 600 edges. The Swift side (`--editor`) builds in CI only, since this environment has no Swift toolchain.
