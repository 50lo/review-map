# Plan

Review Map becomes the review tool Anton uses as a maintainer, for Swift, TypeScript, Go, Rust, and Kotlin. It's a personal tool, not a product: shortcuts are fine where they save real work, and the code stays simple and maintainable.

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
| 5 | Go |
| 6 | Rust |
| 7 | Kotlin |
| 8 | Faster Swift indexing |

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

TypeScript is the first new language; Go, Rust, and Kotlin follow the same path (steps 5 to 7). It brings tree-sitter with the TypeScript grammar, TypeScript's declarations, its reference and risk queries, and npm workspace and `tsconfig` components. Exact resolution comes from the language's own indexer, which type-checks the source without a full build. The analyzer installs or downloads dependencies before indexing:

| Language | Indexer | Needs |
| --- | --- | --- |
| TypeScript | `scip-typescript` | `tsconfig`; `node_modules` for third-party types |

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

### Adding a language

Go, Rust, and Kotlin each go through the same stages, in this order:

1. **Parsing**: the tree-sitter grammar as a SwiftPM package, declarations from a walk over the tree, name references from imports, and test files.
2. **Components**: the language's manifests, a test component per package, platform modules, and lockfile pins.
3. **Contracts and risk**: contract flags, settings flags, and a risk table written as tree-sitter queries.
4. **Structural review**: how the language declares conformance, and isolation where it has one.
5. **Index mode**: the language's SCIP indexer, cached per commit.
6. **Viewer**: icon, highlighting, entity kind names, and flag weights.
7. **Real use**: a fixture pair, and a run on the last 40 commits of a real repo.

Two pieces of shared work come before Go:

- The viewer's language knowledge (extensions, manifests, icon, Shiki language, kind names) becomes one table, so a language is one entry in it.
- Structural review's Swift and TypeScript assumptions move behind `Language`: public API is Swift's access levels or TypeScript's exports, conformers are found by inheritance clauses, and isolation comes from Swift attributes.

| Language | Grammar | Components | Indexer | Needs |
| --- | --- | --- | --- | --- |
| Go | tree-sitter-go | Packages inside `go.mod` modules and `go.work` | `scip-go` | Downloaded modules |
| Rust | tree-sitter-rust | Cargo workspace members and their targets | `rust-analyzer scip` | `cargo metadata`; build scripts and proc macros compile |
| Kotlin | tree-sitter-kotlin | Gradle modules and their source sets | `scip-java` with the Kotlin compiler plugin | A Gradle build |

Go comes first: a package is a directory, so components map directly, and scip-go needs no build. Kotlin comes last: it has no indexer that works without a build, so it ships with name matching, and index mode waits for measurements, as Swift's does.

### 5. Go

- **Declarations**: types, functions, methods (scoped to their receiver type), interfaces and their methods, constants, and variables. A capitalized name is exported, which is Go's access level.
- **References**: `pkg.Name` selectors resolved through the file's imports, including aliases and dot imports.
- **Components**: one component per package directory, inside the module its `go.mod` declares; `go.work` lists the modules. `_test.go` files go to the package's test component, and `testdata` folders are skipped. Pins come from `go.mod` `require` lines. The standard library is every import path whose first element has no dot.
- **Contracts and risk**: exported API added, removed, or changed; interface method sets; struct field tags (`json:`, `db:`); `go` and `toolchain` directives. Risk marks: `go` statements, ignored errors, `panic`, `recover`, `unsafe`, and type assertions without `ok`.
- **Structural review**: interfaces are implicit, so a conformer is a type whose method set includes the interface's methods.

### 6. Rust

- **Declarations**: structs, enums and their variants, traits and their items, `impl` blocks (as extensions; `impl Trait for Type` is a conformance), functions, constants, statics, type aliases, and `macro_rules!`.
- **References**: `use` paths (`crate::`, `super::`, `self::`, external crates) and qualified paths.
- **Components**: Cargo workspace members and their targets (library, binaries). `Cargo.toml` is read with a TOML package, so name matching doesn't need Cargo installed. `tests/`, `benches/`, and `#[cfg(test)]` modules count as tests. Pins come from `Cargo.lock` for direct dependencies. `std`, `core`, `alloc`, `proc_macro`, and `test` are platform modules.
- **Contracts and risk**: `pub` API, trait items, enum variants and `#[non_exhaustive]`, serde derives and attributes, `Send` and `Sync` bounds, `async`; features, edition, and `rust-version`. Risk marks: `unsafe`, `unwrap`, `expect`, `panic!`, `todo!`, `unimplemented!`, `unreachable!`, indexing, `as` casts, and `block_on`.
- **Structural review**: conformers from `impl Trait for Type`; a trait's default methods count as implementations.
- **Index mode**: a failed build script leaves the index partial, as a failed install does for TypeScript.

### 7. Kotlin

- **Declarations**: classes (data, sealed, enum, value, annotation), interfaces, objects and companions, functions including extension functions (scoped to their receiver type), properties, and type aliases. Kotlin's default visibility is public.
- **References**: imports, including star imports, and names from the same package, which need no import.
- **Components**: Gradle modules from the `include` calls in `settings.gradle.kts` or `settings.gradle`, read as text. Test source sets (`src/test`, `src/androidTest`, Kotlin Multiplatform's `*Test`) go to the module's test component. External dependencies are the ones build files declare, with versions from `gradle/libs.versions.toml`. Packages come from file headers and resolve imports across modules, since a module holds many packages. `kotlin`, `java`, `javax`, and `android` are platform modules. Java files in a module are not parsed.
- **Contracts and risk**: public API, nullability of parameters and results, `suspend`, data class properties, serialized and persisted shapes (`@Serializable`, Room `@Entity`), sealed subclasses and enum entries, `open`, `final`, and `abstract`; `minSdk`, `targetSdk`, `compileSdk`, `jvmTarget`, and the Kotlin version. `AndroidManifest.xml` is a contract file (permissions, exported components). Risk marks: `!!`, `lateinit`, unchecked `as`, `runBlocking`, `GlobalScope`, `TODO()`, and `error()`.
- **View code**: `@Composable` functions and subclasses of `View`, `Fragment`, and `Activity`.
- **Structural review**: conformers from supertype lists; isolation from `@MainThread`, `@UiThread`, and Android UI classes, where the innermost `Dispatchers` block overrides it.
- **Index mode**: not at first. scip-java with the Kotlin compiler plugin needs a Gradle build, which has Swift's cost, so it is measured on a real project before it is built.

### 8. Faster Swift indexing

Swift has no exact resolution without a build for Xcode and Bazel projects, so the build gets cheaper:

- Measure where the time goes.
- Keep one warm output base or DerivedData per repo instead of a fresh one per build, so the head builds incrementally on top of the base.
- Build only the changed modules and the modules that depend on them.
- Improve the name fallback: infer the receiver's type from local declarations (`let x: T`, `T(...)`, typed parameters and properties), and draw links that stay guesses differently from exact ones.

## Future improvements

- Add SwiftFormat to the project.
- Add Sublime Text (`subl`) to the editor presets.
- Resolve `tsconfig` path aliases (`@/`, `~/`) in TypeScript name matching.
- Parse JavaScript files (`.js`, `.jsx`, `.mjs`, `.cjs`) with the TSX grammar.
- Parse Java files in Kotlin modules.
