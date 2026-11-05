# Progress

Steps from [plan.md](plan.md). Each one is usable on real PRs before the next starts.

| # | Step | Status |
| --- | --- | --- |
| 1 | Map: selection glitch, collapse and expand, editor command | Done; the glitch fix still needs a check on a large real model |
| 2 | Language-neutral core | Done |
| 3 | TypeScript | Done; index mode still needs a run on a pnpm or yarn monorepo |
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
- Checked in Chromium at desktop and phone widths, in light and dark mode, on the fixture and on a synthetic model with 360 components and 600 edges. `--editor` was checked end to end with `reviewmap view` on a model of this repo.

## Step 2 notes

- The `Language` protocol is the seam. A language supplies its parser, the components its manifests declare, its platform modules, its lockfile pins, its contract flags and their risk weights, its non-code contracts and build-setting flags, what counts as view code, and its index.
- Swift's code lives in `Sources/ReviewMapCore/Swift/`: SwiftSyntax parsing and risk marks, SPM and Xcode components, contract flags, Apple's non-code contracts, Package.resolved pins, and the index store build. The core keeps folder components, splitting, `reviewmap.yml` rules, matching, name resolution, edges, usage, regions, and risk scoring.
- Risk marks have language-neutral kinds: crash, check, flow, concurrency, and isolation.
- Contract flags carry the language's prefix (`swift:codable-shape`). The model is version 2, and `analyzer.languages` lists the languages in the change. The viewer shows flags without the prefix.
- Index mode runs per language. A language whose index can't be built falls back to name matching at both sides without affecting the others.
- `SCIP.swift` reads SCIP indexes into the same per-side references the index store gives: definitions place each symbol, every other occurrence is a reference, and local symbols resolve only within their document. It is tested with indexes written field by field; no indexer runs it yet.
- Tree-sitter comes with TypeScript in step 3, where its first grammar is used.
- On IceCubesApp's last 10 and 40 commits and on two ranges of this repo, the model is the same as before the change apart from the flag prefix.

## Step 3 notes

- Tree-sitter's C library (0.25.10) and the TypeScript and TSX grammars (tree-sitter-typescript 0.23.2) come in as SwiftPM packages. `TreeSitter.swift` wraps parsing, nodes, tokens, and queries, and applies the `#eq?`, `#not-eq?`, `#match?`, `#not-match?`, and `#any-of?` predicates that the C library leaves to its caller.
- Declarations come from a walk over the tree, since nesting, modifiers, and headers need its structure. References and risk marks are queries. The risk table has one pattern per signal, and a pattern that names a node a grammar lacks (TSX has no `<T>x` assertions) is left out for that grammar.
- TypeScript declarations use the existing entity kinds; the viewer names them as TypeScript does (interface, member, constructor, type, function, property, variable). The model only gains two component kinds, `npmPackage` and `tsconfig`.
- Only imported names are reference candidates. `NameRef` carries the file a relative import points at (`source`) and the package a bare import names (`module`), and the core uses them before the declaration table. Rust and Go imports can fill the same fields.
- Test files go to a test component next to their package (`npm:<name>:tests`). The core's test paths now include `.test.` and `.spec.` files and `__tests__`, `test`, `tests`, and `e2e` folders.
- A `tsconfig.json` in or above a package, such as a workspace root's base config, is not a component. `@types/<name>` packages count as the module they type.
- Lockfile pins cover the packages a `package.json` lists; transitive ones are left out. pnpm 10 and later write the lockfile as two YAML documents, and both are read.
- Index mode installs dependencies with scripts off and runs scip-typescript 0.4.0 through `npx`. A failed install doesn't stop indexing; `SideIndex.warnings` reports it as `index-partial`. SCIP references to modules are skipped, since a module has no declaration to point at.
- On this repo's viewer change in 2b36566 (Swift and TypeScript together), name matching takes 3s. Index mode, with `npm ci` in `viewer/`, takes 9s per side and finds uses from the viewer tests that name matching misses. On trpc/trpc (a pnpm workspace, 288 components, its last 40 commits), name matching takes 9s; the ambiguity warnings left come from `~/` path aliases.
