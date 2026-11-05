# Plan

Review Map becomes the review tool Anton uses as a maintainer, for Swift, TypeScript, Rust, and Go. It's a personal tool, not a product: shortcuts are fine where they save real work, and the code stays simple and maintainable.

Progress is tracked in [progress.md](progress.md).

What carries over from the prototype (see [archive/progress.md](archive/progress.md)):

- The visual map of the change, the code behind each block and arrow, and opening changed code in the IDE are the valuable parts.
- References must be resolved exactly. Name matching creates false links that make the map misleading.
- Building the whole project to index it is too slow: a clean build of one target project takes about 20 minutes.
- LLM notes on single fragments rarely find what CI review agents miss. A review of the change's structure is the direction to try.

## Steps

Each step is usable on real PRs before the next starts.

| # | Step |
| --- | --- |
| 1 | Map: selection glitch, collapse and expand, editor command |
| 2 | Language-neutral core |
| 3 | TypeScript |
| 4 | Structural review |
| 5 | Faster Swift indexing |

### 1. Map

**Selection glitch.** On large graphs, selecting a node or an edge makes parts of the map disappear, and of the interface and code pages too. Selection dims almost every node (opacity 0.22) and edge (0.08), each with an opacity transition, and the map stays rendered under the pages, which are an overlay above it. Fixes:

- Stop rendering the map while a page is open, keeping its viewport.
- Dim with muted colors instead of opacity, and drop the opacity transitions.
- Set `onlyRenderVisibleElements` on React Flow.

If the map still glitches after these, replace React Flow with Cytoscape.js, which draws on canvas, supports compound nodes, and has an ELK adapter, so the layout code carries over.

**Collapse and expand.** Large graphs aren't readable even when they render. Groups collapse into a single node, the default view is the changed subgraph and its direct neighbors, and a click expands a group or a neighbor.

**Editor command.** Open in IDE runs a configurable command (`code -g`, `zed`, `idea --line`, `xed --line`) instead of Xcode only.

### 2. Language-neutral core

The core stays in Swift: git export, diffing, components, regions, risk, the LLM layer, and the model. Each language plugs in:

- **Parsing**: tree-sitter for TypeScript, Rust, and Go, through its C library. Swift keeps SwiftSyntax, which its contract flags depend on.
- **Components**: Cargo workspace members, Go packages, npm workspaces or `tsconfig` projects, alongside SPM, Xcode, and Bazel targets.
- **Risk signals**: a table per language, written as tree-sitter queries (for example `unsafe`, `unwrap`, `panic!` in Rust; goroutines and ignored errors in Go; `any`, `as`, `!` in TypeScript).
- **Resolution**: references come in as SCIP. Swift's IndexStoreDB reader sits behind the same interface. Name matching stays as the fallback.
- **Model**: contract flags get a language prefix; everything else stays language-neutral.

### 3. TypeScript

TypeScript is the first new language; Rust and Go follow the same path. It brings tree-sitter with the TypeScript grammar, TypeScript's declaration, reference, and risk queries, and npm workspace and `tsconfig` components. Exact resolution comes from the language's own indexer, which type-checks the source without a full build. The analyzer installs or downloads dependencies before indexing:

| Language | Indexer | Needs |
| --- | --- | --- |
| TypeScript | `scip-typescript` | `tsconfig`; `node_modules` for third-party types |
| Go | `scip-go` | Downloaded modules |
| Rust | `rust-analyzer scip` | `cargo metadata`; build scripts and proc macros compile |

Index results are cached per commit, as they are for Swift.

### 4. Structural review

Review Map has both sides of the whole repo, the dependency graph, and usage; CI review agents only see the diff. Structural review uses that.

**Deterministic checks**, no LLM:

- New dependency cycles.
- Edges that break the layering declared in `reviewmap.yml`.
- New external dependencies.
- New public API with no callers outside tests.
- Code left unused after its callers were removed.
- A changed protocol or interface whose conformers weren't all updated.
- Changed entities that no test references.

**One LLM pass per PR**, replacing the per-fragment notes and removal candidates; entity and component summaries stay. Its input is the PR description, the edge diff with sample references, the interface diff, usage (callers, their count and isolation, the types at call sites), and existing declarations with similar names. It asks whether the shape of the change matches its intent, whether responsibilities sit in the right place, what's missing, and what's duplicated, and it flags unnecessary complexity:

- Checks that can't fail: nil checks, guards, and validation for states the types or every caller already rule out, and catch blocks for errors nothing throws.
- Concurrency protection for impossible scenarios: locks, actors, queues, or atomics around state only one isolation domain touches.
- Algorithms and data structures beyond what the input needs: caches, memoization, or indexes for small inputs or one-shot calls.
- Abstractions without a second use: protocols with one implementation, generics, factories, and options nobody sets.
- Retries, fallbacks, and timeouts for failures that can't happen on that path.
- Re-implementations of helpers the repo already has.

Each finding cites its evidence from the usage data (for example, "the only caller is `@MainActor`, so this lock guards nothing"), says what to remove or simplify, and is anchored to a component, an edge, or an entity, so it shows on the map.

### 5. Faster Swift indexing

Swift has no exact resolution without a build for Xcode and Bazel projects, so the build gets cheaper:

- Measure where the time goes.
- Keep one warm output base or DerivedData per repo instead of a fresh one per build, so the head builds incrementally on top of the base.
- Build only the changed modules and the modules that depend on them.
- Improve the name fallback: infer the receiver's type from local declarations (`let x: T`, `T(...)`, typed parameters and properties), and draw links that stay guesses differently from exact ones.

## Future improvements

- Add SwiftFormat to the project.
- Add Sublime Text (`subl`) to the editor presets.
