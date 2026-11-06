# Progress

Steps from [plan.md](plan.md). Each one is usable on real PRs before the next starts.

| # | Step | Status |
| --- | --- | --- |
| 1 | Map: selection glitch, collapse and expand, editor command | Done; the glitch fix still needs a check on a large real model |
| 2 | Language-neutral core | Done |
| 3 | TypeScript | Done; index mode still needs a run on a pnpm or yarn monorepo |
| 4 | Structural review | Done; the LLM review still needs runs with the real `claude` CLI on real PRs |
| 5 | Go | Done |
| 6 | Rust | Not started |
| 7 | Kotlin | Not started |
| 8 | Faster Swift indexing | Deferred; only big projects are slow |

## Step 1 notes

- **Selection glitch.** The map has no opacity left: dimmed nodes and edges, and unchanged edges, use colors mixed with the background, and the opacity transitions are gone. While an interface or code page is open, the map and the side panel under it are `visibility: hidden`, so they aren't painted and keep their viewport. React Flow renders only the elements in view (`onlyRenderVisibleElements`). The glitch didn't reproduce in headless Chromium, which has no GPU, so whether this fixes it is still to be seen on the model where it happened. If it doesn't, the next move is Cytoscape.js.
- With culling on, React Flow's `fitView` only saw the nodes it had already measured and zoomed in on them after a relayout. Nodes now carry their layout size, and the map fits to the layout's own bounds.
- **Collapse and expand.** A target split into folders collapses into one node, drawn as a stack with the number of components inside, and edges into it are bundled per pair of drawn nodes. A bundle takes the status its edges share, or changed when they differ. Groups start collapsed when more than 40 components are visible. Collapse state starts over when the scope or the test filter changes.
- A focus inside a collapsed group opens the group: a component or review item opens the groups around it, and an edge also opens its ends, since a group's own edge would otherwise be drawn inside a bundle. Selecting a collapsed group leaves it collapsed.
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
- TypeScript declarations use the existing review item kinds; the viewer names them as TypeScript does (interface, member, constructor, type, function, property, variable). The model only gains two component kinds, `npmPackage` and `tsconfig`.
- Only imported names are reference candidates. `NameRef` carries the file a relative import points at (`source`) and the package a bare import names (`module`), and the core uses them before the declaration table. Rust and Go imports can fill the same fields.
- Test files go to a test component next to their package (`npm:<name>:tests`). The core's test paths now include `.test.` and `.spec.` files and `__tests__`, `test`, `tests`, and `e2e` folders.
- A `tsconfig.json` in or above a package, such as a workspace root's base config, is not a component. `@types/<name>` packages count as the module they type.
- Lockfile pins cover the packages a `package.json` lists; transitive ones are left out. pnpm 10 and later write the lockfile as two YAML documents, and both are read.
- Index mode installs dependencies with scripts off and runs scip-typescript 0.4.0 through `npx`. A failed install doesn't stop indexing; `SideIndex.warnings` reports it as `index-partial`. SCIP references to modules are skipped, since a module has no declaration to point at.
- On this repo's viewer change in 2b36566 (Swift and TypeScript together), name matching takes 3s. Index mode, with `npm ci` in `viewer/`, takes 9s per side and finds uses from the viewer tests that name matching misses. On trpc/trpc (a pnpm workspace, 288 components, its last 40 commits), name matching takes 9s; the ambiguity warnings left come from `~/` path aliases.

## Step 4 notes

- Findings are a new top-level `findings` list in the model (version 3). Each has a kind, a severity, a one-sentence message, evidence, an optional suggestion, anchors (components, edges, or review items, the first being the main one), and an optional code location. Deterministic findings come from the analyzer (`Checks.swift`); the LLM's are added by the annotator (`StructuralReview.swift`), and annotating again replaces them.
- The seven checks from the plan are `cycle`, `layering`, `new-external`, `unused-api`, `orphaned`, `conformers`, and `untested`. The README lists what each one finds.
- Cycles are found between targets: split folders count as their target, because folders of one module referring to each other is normal. A head cycle is new unless all its targets were already in one cycle at base.
- The layering is declared with a new `layers` list in `reviewmap.yml`, top to bottom. Layers name components by glob, and component rules can still set `layer`. Split folders take their target's layer. The config comes from the head, so it applies to both sides. Violations are grouped per pair of targets, so a manifest dependency and the code under it are one finding.
- Without index mode, `unused-api`, `orphaned`, and `untested` use identifier occurrences: a declaration counts as used when its name appears anywhere outside itself. That is conservative for the unused checks and generous for `untested`. With index mode, references come from the index. Initializers, overrides, requirements, entry points, and members of a type or extension with an inheritance clause (possible witnesses) are skipped, since they are called without being named.
- `untested` is one finding per component, and only for components tests reach at all (a test component depends on them, or they hold test files). Without that limit every script folder got a finding.
- `conformers` finds conformers by their inheritance clauses; it reports a requirement no conformer implements (unless an extension of the protocol has a default) and implementations that didn't change with a changed signature. On the TypeScript fixture it catches `MemoryRepository`, which doesn't implement the new `clear()`.
- The usage the LLM review needs is computed by the analyzer: `usedBy` entries carry the isolation the reference runs in (a global actor attribute, `nonisolated`, an actor, or a SwiftUI view), and added review items carry `similar`, existing declarations with close names (same name with at least two words, most of the same words, or a spelling within two edits).
- The LLM review is one call per change, alongside the per-component batches. The per-component batches keep region risk, context pruning, and summaries; region notes and removal candidates are gone, and the prompt version is 2. The change's description comes from `--description`, else `gh pr view` on the head branch, else the commit messages.
- In the viewer, the structural review leads the side panel's overview. Components carry a findings count on their top border, collapsed groups count what's inside, and edges with findings are labeled. Component, edge, and bundle panels and levels 2 and 3 list the findings anchored there; level 3 also lists similar existing declarations for an added review item. The LLM's findings follow the LLM toggle.
- Checked in Chromium at desktop and phone widths, in light and dark mode, on the basic fixture with a `layers` config and the fake CLI. Not yet run on a real PR with the real `claude` CLI, so the prompt and the 12-finding limit are untested against a model.

## Step 5 notes

- Go parses with tree-sitter-go 0.25.0. Methods are scoped to their receiver's type and are its children when the type is in the same file; otherwise they stay top level with the type as their scope. Struct fields are `var`s whose tag is compared with the modifiers, so a tag change is a `modifiers` change with a `field-tag-changed:<key>` flag. Labels keys hold one label per parameter, which gives conformance its arity.
- References: `pkg.Name` resolves through the file's imports (aliases, the import path's last element without a major version, dot imports). Unqualified names only reach another component from test files, which are a component of their own, and through dot imports. Two core changes came with it, both without changing the Swift and TypeScript snapshots: a reference that names a module now only resolves to that module (before, it fell back to any visible declaration, which linked `json.Marshal` to an in-repo `Marshal`), and an unqualified name prefers the file's own module (a Go test file uses its package's names, not those of a package it imports).
- The standard library is any import path whose first element has no dot. The `Language` protocol gained `isPlatformModule`, which defaults to the `platformModules` set; `ParsedFile.isGenerated` lets a language mark a file generated from its contents (Go's `Code generated ... DO NOT EDIT.` header).
- Components: one per package directory inside the nearest `go.mod`, named by import path; `_test.go` files go to `go:<import path>:tests`; `vendor` and `testdata` aren't parsed. A `go.work` needs nothing extra, since every module it lists has its own `go.mod`. A module's `go`, `toolchain`, and `replace` settings live on its root package, which is created without files when the root has none, so the settings review item reads "<module> build settings".
- Conformers: the types whose method set covered the interface at base, in any package, matched by name and parameter count, with embedded interfaces expanded; an embedded interface outside the repo makes the set unknown, so there are no conformers rather than false ones. Embedded fields count as implicitly used.
- Index mode: scip-go v0.2.9 (now at `github.com/scip-code/scip-go`) writes occurrence ranges as a message (field 8) instead of packed integers, so the SCIP reader learned that form. Each module is indexed on its own and cached per commit and module. scip-go comes from the PATH, or is installed with `go install` into the index cache.
- Real repo: uber-go/zap, the last 40 commits (46 files, +639/-381, 6 modules, 142 Go files), release build on Linux. Name matching takes 1.0 s; index mode takes 39.5 s the first time (module downloads and scip-go for 6 modules at both sides) and 1.7 s cached. Both find 60 components and 112 edges. The first run showed 36 `ambiguous-name` warnings from test files using their own package's names (`DebugLevel` in zap and zapcore), an `orphaned` finding for an embedded `sync.Once`, `api-added` on new `TestX` functions, and `field-added` for an unexported field; after the fixes name matching has 2 ambiguous names left (`Field` in zap and zapcore). Index mode resolves those, finds 3 new exported functions that only tests call (`unused-api`), and differs from name matching only in test callers. The base's `tools` module (a `//go:build tools` file) has no index data and is reported as `index-partial`.
- The viewer has a Go entry in its language table (Simple Icons mark, Shiki's `go` grammar, `go.mod`/`go.sum`/`go.work` manifests, and kind names: interface, type, method or function, field or variable) and weights for Go's flags. Checked in Chromium at desktop and phone widths, in light and dark mode, on the Go fixture model.
- Not checked: the Bazel build. `MODULE.bazel` and `BUILD.bazel` list the new grammar, but Bazel wasn't available, so `MODULE.bazel.lock` may need a refresh.

## Shared groundwork for new languages

- The viewer's Swift and TypeScript definitions now live in one plain table in `viewer/src/languages.ts`: source extensions, manifests and lockfiles, component kinds, icons, Shiki grammars, and review item kind names. Badge ordering and the `Language` type derive from that table.
- `Language` supplies public API classification, implicit callers, conformer discovery with per-requirement implementation matches, and reference isolation. Checks and conformer context use the same conformance hook while preserving their existing lookup rules. The hook has access to both sides and all components for Go's implicit interfaces; isolation receives the parsed file and reference line, and Kotlin can record dispatcher ranges during parsing.
- Checks.swift keeps only implicit-caller rules that follow from the shared declaration shape (initializers, overrides, protocol requirements, possible witnesses); names and attributes belong to each language. TypeScript uses the default nil isolation.
- The model format is unchanged, and the Swift and TypeScript fixture snapshots are unchanged.
