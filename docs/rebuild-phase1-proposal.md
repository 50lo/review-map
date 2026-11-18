# Review Map: phase 1 rebuild proposal

Review Map has reached a useful feature set. Rebuild it as a reliable personal application, preserving the review flow and visual layout while improving correctness, responsiveness, and maintenance. The prototype is a reference, not an exact specification.

This proposal supersedes the earlier recommendation to make compiler indexing an optional later enhancement. Index mode became the prototype's default because name matching produced too many false positives. The rewrite can begin with syntax-only analysis, but compiler indexing belongs early in phase 1, followed immediately by manual comparisons on real projects.

This is a proposed implementation plan. It does not itself modify or ratify Statute rules or decisions.

All rebuild implementation will be done on a long-living branch named `rebuild`. Start new feature branches off `rebuild` and merged them back to `rebuild` when feature implementation is finished. 

**Phase 1 scope**

| Area | Choice |
| --- | --- |
| Platform | macOS first. |
| Application | Tauri 2 with bundled UI assets; no HTTP server or port to manage. |
| UI | React, React Flow, ELK, and Shiki. Preserve Map → Component → Review item, code context, findings, risk ordering, notes, and reviewed marks. |
| Core and repository access | Rust and gix. Read committed content directly; materialize source trees where Bazel or other tools require them. |
| Swift | Bazel projects; SwiftSyntax through a bundled helper for parsing, with compiler-backed reference resolution. |
| Kotlin | Bazel projects; tree-sitter for syntax and the existing Kotlin compiler-analysis approach for references. |
| TypeScript/TSX | Yarn projects and workspaces (Classic, and Berry since 2026-11-19), and TypeScript built with Bazel (rules_ts with rules_js); tree-sitter for syntax and TypeScript-backed indexing. |
| Launching | `reviewmap` opens or focuses the app and passes the repository, refs, and working directory. |

Go, Rust language support, Gradle, SwiftPM, direct Xcode build orchestration, and other package managers (pnpm, npm-only projects, Bun) are outside phase 1. On 2026-11-19 Yarn Berry (2 and later) moved into phase 1 (epic rm-t9hw): a Berry root is installed in the app-owned tree with the project's own Yarn release, install scripts off, and the `node-modules` linker forced whatever its `.yarnrc.yml` sets, so the rest is the Yarn Classic path. Index mode therefore runs the project's committed Yarn release and Yarn plugins.

On 2026-11-16 the user moved TypeScript built with Bazel into phase 1. Any rules_ts workspace that uses aspect_rules_js is supported, whatever lockfile its `npm_translate_lock` reads (normally `pnpm-lock.yaml`; a converted `yarn.lock` works the same way). The lockfile is Bazel's business there, so pnpm as a package manager stays out of scope. Review Map installs no packages for Bazel workspaces: Bazel builds, in the app-owned tree, the npm links the scope targets depend on (since rm-9e2v; before, the scope targets themselves) and fetches `node_modules` itself, and indexing uses what Bazel laid out. Java and Objective-C review support are out of scope for the foreseeable future. They may still need compilation as dependencies of supported targets.

Report files and standalone analysis are not product requirements. Internal formats and versioning should serve implementation and testing. Preserve the supported languages' existing contract checks and optional LLM assistance; a deterministic review must work independently of LLM completion.

**User-visible analysis behavior**

Show the structural review as soon as it is available, then automatically refine it with indexing. Display progress and allow cancellation. The initial view is preliminary: it shows no name-matched links, only links that syntax alone proves (for example within the same file or local scope), and suppresses conclusions requiring complete reference coverage, such as unused declarations, until the necessary evidence exists. Name matching produced the false positives that made index mode the prototype's default, so showing name matches first and withdrawing them later would mislead. If indexing fails or is cancelled, keep the usable results and clearly indicate incomplete coverage.

Preserve the selected review item, notes, and reviewed state as results improve. Provide a comparison control during validation so the user can inspect indexed and non-indexed results for the same revisions. Starting without indexing is an implementation milestone, not a decision to accept the prototype's false-positive rate.

Scope, visibility, imports, aliases, and receiver handling remain language-specific. A module's local `logger` must not create links to unrelated declarations elsewhere. Ambiguity stays unresolved. Missing coverage must not become evidence of no callers, and different coverage between base and head must not manufacture added or removed dependencies. Record Java and Objective-C files in the relevant review scope as coverage gaps.

**A shared Bazel foundation**

Use configured Bazel queries to obtain target dependencies, source ownership, and configuration. Queries are usually fast in the user's projects, but a historical revision needs a real source tree and may require cold graph loading or dependency fetching. gix alone cannot supply a workspace to Bazel.

Maintain reusable, app-owned base and head directories outside the reviewed repository, one pair per repository and per nested Bazel workspace within it, with stable paths and dedicated output bases. Update each directory to the requested revision only between jobs, removing obsolete inputs and preventing concurrent mutation. Retain bounded build artifacts and share repository-download and action caches where compatible. Stop owned Bazel servers when the app exits; do not expunge output bases after every review. Server shutdown still loses in-memory analysis state, so reopening is distinct from another review in the same session.

Preserve nested Bazel workspace discovery, explicit target selection, and build configuration. Keep configured target identity separate from language packages and lexical scope, including sources shared by several targets. Avoid defaulting to every target in a monorepo when a selected application and its tests define the review scope.

Prioritize changed targets, their required dependencies, and potential callers within that scope. Inspect both revisions' graphs. A changed library's outgoing references can be resolved before all its consumers are indexed, but complete caller information requires those consumers. Prioritization changes when results become available; it must not silently narrow the claimed coverage.

**Swift: preserve syntax fidelity and reduce compiler work**

Keep SwiftSyntax for declarations, signatures, bodies, and syntax-based contracts. It parses source without building the reviewed project. Batch work through an app-owned helper rather than launching a process per file. Tree-sitter-swift is a possible later simplification only if its coverage is demonstrated.

Bring the existing compiler index integration into the rewrite early as an accuracy baseline. Then investigate requesting only the compiler and index artifacts needed for review, avoiding unrelated linking, packaging, and test execution. Preserve the correct application/platform configuration when reaching library targets. Collect declared index artifacts explicitly, including cache hits; the global index directory alone can omit cached dependencies.

Evaluate targeted index preparation using a Bazel aspect or SourceKit's Bazel integration before adopting a full language-server stack. The existing integration's approach of reaching a library through its parent application target is relevant to configuration correctness and cache reuse. Its benefit for Review Map must be measured. A broadly used API change can still require substantial dependency and caller indexing.

Reuse indexes produced by Review Map and, where verifiable, by normal Swift development builds. Discover locations from the local Bazel setup, support an explicit override, and translate paths to repository-relative identities. Verify relevant sources, dependencies, generated inputs, target configuration, SDK, toolchain, and coverage. A recent timestamp or unchanged individual file is insufficient. Decline foreign indexes whose provenance cannot be established. An index for head does not describe base.

**Kotlin: fix identity, then optimize the existing pipeline**

Retain the current approach: a Bazel aspect obtains Kotlin sources and compile classpaths, dependency jars are prepared, and scip-java's Kotlin analysis runs with a compatible JDK. Ordinary Bazel builds can supply those jars; they do not automatically supply Review Map's Kotlin reference index.

Fix target ownership before treating the compiler path as authoritative. The prototype already scopes some duplicate symbols, but can assign shared files to their first owner and choose the first matching dependency. Preserve each configured target's index separately until ownership is resolved. Map references through actual source or classpath artifact ownership; do not infer identity from a matching symbol name or prefix every symbol with the caller's target. If the indexer lacks the necessary provenance, extend the integration or leave the reference unresolved.

Cache Kotlin indexes per configured target, conservatively invalidating them when source, relevant classpath artifacts, compiler options, toolchain, or indexer version changes. Use bounded concurrency. After correctness is established, evaluate expressing Kotlin indexing as a Bazel action with declared inputs and outputs so Bazel can cache the index itself. Keep the selected indexer version pinned and tested.

**TypeScript and external tools**

Support Yarn workspaces (Classic, and Berry since 2026-11-19, installed with the `node-modules` linker), package exports, and tsconfig project references and path aliases. Deeper TypeScript analysis may install dependencies in the app-owned revision tree using the lockfile, with install scripts disabled as in the prototype. Account for download and installation time, reuse package caches, and report failures or incomplete resolution clearly. Do not install into the user's working tree. Because scripts are disabled, `postinstall` code generation does not run and its generated sources and types are missing. This is an accepted coverage gap: references into generated code stay unresolved and are reported as incomplete coverage, never as missing callers.

Obtain indexers the same way as the prototype. scip-java's release launcher is downloaded on first use from its GitHub release at a pinned version, checked against the published SHA-256, and kept in the app's tool cache. scip-typescript runs through `npx` at a pinned version. The JDK is not downloaded: as in the prototype, Kotlin indexing needs a user-installed JDK 17 or newer, and its absence makes Kotlin fall back with incomplete coverage. Keep the prototype's overrides for using another scip-java or scip-typescript.

Tool discovery must work from both Finder and terminal launches. A Finder launch lacks the shell's PATH and environment variables, so resolve tools (Bazel, Yarn, Node, `java`, and the `claude`/`codex` CLIs) from known install locations or a configured absolute path rather than the inherited PATH. The LLM CLIs keep their sign-in in their own configuration and credential storage, so it works from either launch. API keys provided only through shell environment variables are not supported from Finder launches. If this proves harder than expected, Finder launches may be dropped in favour of terminal launches only; this is a personal application, and simplicity of implementation outweighs that convenience. The app owns cancellation and cleanup of its indexers, helper processes, and LLM commands. Avoid shell-environment discovery that can stall startup indefinitely.

**Cache and state policy**

Assume an empty analysis cache: previously accumulated data has been cleared for disk space. The first review must be useful without it. Cache syntax by content, language, and parser version; cache semantic results separately with their relevant inputs and configuration. Reconsider references when dependencies or declarations elsewhere change, even if the referring file is unchanged.

Provide a cache-size limit and eviction. Keep notes and reviewed state separate from disposable analysis/build data. Reuse must work with different local paths and configurations; copying raw indexes between computers is not required for phase 1.

**Implementation and validation order**

1. Bring the review UI into Tauri, with parsing and reusable Bazel workspaces.
2. Connect Swift and Kotlin indexing immediately, including Kotlin ownership corrections.
3. Compare indexed and non-indexed reviews manually on representative real changes before substantial performance optimization.
4. Add TypeScript indexing for Yarn (Classic, and Berry since 2026-11-19) and for Bazel workspaces that build TypeScript with rules_ts.
5. Optimize measured bottlenecks while checking that reference results and coverage remain correct.

Measure empty caches, retained disk caches after reopening, and another review in the same session. Separate workspace preparation, Bazel queries, dependency preparation, index generation, and report/UI work. Record time to the first usable view and to sufficient indexed coverage, false links, missed callers, memory, and disk use.

Include duplicate symbols across targets, shared sources, aliases, partial indexes, mixed-language coverage gaps, different checkout paths/configurations, and a shared API change with many consumers. Compare against the current compiler-backed behavior and manually inspect disagreements; compiler indexes themselves are not infallible. Set performance targets from these projects rather than promising a universal duration.

Carry CORE-001–006 into acceptance tests: merge-base comparison, no writes to the reviewed repository, explicit name-resolution fallback warnings, deterministic results surviving LLM failure, findings anchored to review evidence, and formatting-only changes requiring no review. Update their code links as ownership moves to Rust or helpers. Any change to the guarantees, including warning behavior during preliminary analysis, needs a proposed decision and the required human approval; do not silently rewrite rules to fit the implementation.

**Later additions**

Keep future scope high-level: a branch list for starting reviews in the GUI, additional languages or build systems if needed, Linux/Windows, broader verified index import, and further semantic optimizations. Java and Objective-C analysis are not planned. Phase 1 should remain a focused review application rather than grow into a general-purpose IDE.

Implementation references: [Bazel output directories](https://bazel.build/remote/output-directories), [Bazel action caching](https://bazel.build/remote/caching), [SwiftParser](https://github.com/swiftlang/swift-syntax/blob/main/Sources/SwiftParser/SwiftParser.docc/SwiftParser.md), and [SourceKit Bazel cache handling](https://github.com/spotify/sourcekit-bazel-bsp#bazel-cache-handling).
