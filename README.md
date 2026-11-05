# Review Map

A code review tool that shows a change as structure (components, dependency edges, changed contracts) instead of line diffs. It supports Swift today; TypeScript, Rust, and Go are planned. It has two parts joined by one file: an analyzer that reads two git refs and writes `change-model.json`, and a browser viewer that reads it. The plan is in [docs/plan.md](docs/plan.md).

## Run it

Requires the Swift 6.2 toolchain (Xcode 26) on macOS, Node 20 or later for the viewer, and git. The analyzer also builds and runs on Linux.

```sh
git clone https://github.com/50lo/review-map.git
review-map/scripts/install.sh
cd /path/to/repo
reviewmap
```

`scripts/install.sh` builds the release binary and installs it to `~/.local/bin/reviewmap`, with the viewer and its npm dependencies in `~/.local/share/reviewmap/viewer`. `PREFIX=/some/dir` installs under another prefix. If the `bin` directory isn't on your `PATH`, the script prints the line to add to your shell profile. Run it again after pulling to update; it reinstalls npm dependencies only when they changed. `scripts/install.sh --uninstall` removes both. The installed copy doesn't use the checkout, which can be moved or deleted. `REVIEWMAP_VIEWER` points the binary at another viewer directory.

Without installing, `swift build -c release` and `.build/release/reviewmap` work too, using the viewer in the checkout. On Linux, add `-Xcxx -I<toolchain>/usr/lib/swift -Xcxx -I<toolchain>/usr/lib/swift/Block` to `swift build` and `swift test` (IndexStoreDB's C++ needs those headers); the install script and CI do this.

With no arguments, `reviewmap` compares the branch checked out in the current directory with `main`, writes the change model to `~/.reviewmap/models/<repo>/<head>/change-model.json`, starts the viewer on it, and opens the browser. It's the same as `reviewmap review . --base main --head <current branch> --view`. Nothing is written to the target repo, and each branch keeps its own model, reviewed marks, and notes (a branch name like `feature/login` becomes `feature-login`). When run from a build in the checkout, the first run installs the viewer's npm dependencies. By default the LLM annotator runs through the local `claude` CLI; `--no-llm` skips it.

The subcommands do one step each: `reviewmap analyze` only writes the model (add `--view` to open it), `reviewmap annotate [model]` runs the LLM annotator on an existing model, and `reviewmap view [model]` opens an existing model. Without a path, `annotate` and `view` use the model of the current branch of the repo in the current directory. Options for the default command and `analyze`:

| Option | Meaning |
| --- | --- |
| `[repo]` | Path to the repo, or any directory inside it (default: the current directory). |
| `--base`, `--head` | Any git refs (default: `main` and the current branch). The base is the merge-base of the two, which is what a PR shows. |
| `--no-merge-base` | Compare against `--base` directly. |
| `-o <file>` | Output path, or `-` for stdout (default: `~/.reviewmap/models/<repo>/<head>/change-model.json`). |
| `--config <file>` | A `reviewmap.yml`. By default it's read from the head of the repo, if one exists there. |
| `--dump-package` | Evaluate `Package.swift` with `swift package dump-package` instead of parsing it. More exact for computed manifests, but it compiles and runs the manifest. |
| `--max-refs <n>` | References kept per edge (default 50). |
| `--summary` | Print a short summary to stderr. |
| `--view`, `--no-view` | Serve the result in the viewer and open the browser; stop it with Ctrl-C. On by default, off for `analyze`. |
| `--port <n>` | Viewer port (default 5173). |
| `--editor <e>` | Editor that Open uses: `xcode`, `vscode`, `cursor`, `zed`, `idea`, `webstorm`, `goland`, `rustrover`, or a command with `{file}` and `{line}`, such as `"subl {file}:{line}"` (split on spaces). Default: `$REVIEWMAP_EDITOR`, else `xcode` on macOS. `reviewmap view` takes it too. |
| `--no-llm` | Skip the LLM annotator. |
| `--llm <tool>` | CLI that runs the annotator: `claude` (default) or `codex`. |
| `--llm-model <name>` | Model passed to the CLI. By default the CLI picks. |
| `--llm-command <path>` | Executable to run in place of `claude` or `codex`, with the same arguments. |
| `--llm-cache <dir>` | Cache directory (default `~/.reviewmap/cache`). It must be outside the target repo. |
| `--llm-jobs <n>` | Batches run at the same time (default 4). |
| `--llm-timeout <s>` | Seconds before one CLI call is stopped (default 300). |
| `--index`, `--no-index` | Resolve references exactly from a build's index store (see Index mode). Default: `index.enabled` in `reviewmap.yml`, else off. |
| `--index-builder <b>` | `bazel`, `xcodebuild`, or `swift` (default: `bazel` for a Bazel workspace with targets, else `xcodebuild` where it exists, else `swift build`). |
| `--index-target <label>` | Bazel target to build; repeat for several (default: `top_level_targets` of the repo's rules_xcodeproj `xcodeproj` rule). |
| `--index-project <path>` | The `.xcworkspace`, `.xcodeproj`, or package directory to build: relative to the current directory or the repo root, or absolute. |
| `--index-scheme <name>` | xcodebuild scheme (default: the only one, the one named after the project, or a package's `-Package` scheme). |
| `--index-destination <d>` | xcodebuild destination (default `generic/platform=iOS Simulator`). |
| `--index-cache <dir>` | Where built index stores are kept (default `~/.reviewmap/index`). |
| `--rebuild-index` | Build again even when a commit's index is cached. |

`reviewmap annotate [model]` runs only the annotator on an existing model and writes it back (or to `-o`). It takes the same `--llm…` options.

The analyzer never writes to the target repo. Both trees are exported with `git archive` into a temporary directory, which is removed on exit.

## Languages

The core is language-neutral: git export, components, declaration matching, edges, usage, regions, risk, the LLM layer, and the model. Each language plugs in through the `Language` protocol (`Sources/ReviewMapCore/Language.swift`) with its parser, the components its manifests declare, the modules its platform provides, its lockfile pins, its contract flags and their risk weights, its non-code contracts, and its index. Exact references come in as a `SideIndex` per side: Swift's comes from the compiler's index store, and the languages that follow will read SCIP indexes (`SCIP.swift`) from their own indexers. Swift (`Sources/ReviewMapCore/Swift/`) is the only language so far.

## What it extracts

- **Components**: SPM targets (from every `Package.swift`, including local packages), Xcode native targets (with XcodeProj: build-phase files and Xcode 16 synchronized folders), and top-level folders for any remaining files. A target with more than 30 source files is split by folder, recursively, up to depth 3. Split folders keep a `parent` pointing to their target. Third-party packages become `external` components.
- **Dependency edges**: `import` statements, target dependencies in manifests, and type-level references. By default references are resolved by name against a table of top-level declarations; a reference only counts when the referring file can see the declaring module (same module or imported), and ambiguous names are recorded in `warnings` and not resolved. Index mode resolves every reference exactly instead. `analyzer.resolution` records which was used. Each edge is `added`, `removed`, `changed` (the set of referenced symbols changed), or `unchanged`, and keeps its references.
- **Entities**: types, extensions, functions, initializers, properties, enum cases, and typealiases, matched between base and head by component, scope, name, and kind. Overloads are paired by exact signature, then by argument labels. The change kinds are `added`, `removed`, `signature`, `body`, `modifiers`, and `cosmetic` (trivia only). `changes` lists every aspect that changed. A type appears as an entity only when its own header changed or it carries contract flags; its members are reported one by one.
- **Contract flags**: prefixed with their language, as in `swift:codable-shape`. Swift's are `protocol-requirement-added|removed|changed`, `conformance-added|removed:<P>` (compared per type, across its extensions), `conformance-isolation-changed:<P>`, `access-changed:<a>-><b>`, `async-…`, `throws-…`, `typed-throws-changed`, `mainactor-…`, `nonisolated-…`, `sendable-…`, `kind-changed:class->actor`, `enum-case-added|removed|changed`, `codable-shape`, `swiftdata-model-changed`, `observable-state-changed`, `observable-added|removed`.
- **Non-code contracts**: `Info.plist` (plus `url-schemes-changed`), entitlements, `PrivacyInfo.xcprivacy`, and Core Data models appear as `file` entities. Target build settings appear as `target` entities: Package.swift `swiftSettings`, and Xcode settings such as `SWIFT_DEFAULT_ACTOR_ISOLATION`, `SWIFT_STRICT_CONCURRENCY`, and `SWIFT_VERSION`. Their flags include `default-isolation-changed`, `strict-concurrency-changed`, `swift-features-changed`, `swift-version-changed`, and `deployment-target-changed`.
- **External packages**: `Package.resolved` pins that were added, removed, or bumped.
- **Usage**: `usedBy` lists declarations in other components that reference an entity, and `dependsOn` lists what the entity references in other components. An entity is an interface when it's `public`/`open`/`package`, used from another non-test component, or a requirement or case of an interface type.

- **Review regions**: each non-cosmetic changed entity gets one region per run of changed lines (compared ignoring indentation, spacing, and blank lines). A run with head lines is a `review` region; a run that only deletes lines is a `removed` region on the base side, with `anchor` set to the head line it followed. A new or deleted declaration is one region, and a type's region covers only its header, since its members are entities of their own. Flags that a type carries for its members (a Codable shape, an enum case) put a region on its declaration line.
- **Risk**: each region combines its signals as `1 - Π(1 - weight)`. High (0.6): a contract flag on an interface entity, a concurrency or persisted-model flag, an isolation annotation in code (`@MainActor` or `@Sendable` closures, `nonisolated(unsafe)`), or a removed check (`guard`, early return, `throw`, `precondition`, `assert`). Medium (0.3): other contract flags, a changed interface signature, a removed interface declaration, new crash points (force unwrap, `try!`, `as!`, `fatalError`), tasks, continuations, and locks added or removed, and changed control flow (branches, loops, `catch`, `try?`). Control flow in SwiftUI view code (a `View` type, `some View`, or a `ui` layer) counts 0.15. Every region adds 0.1, and an interface entity adds 0.05 per other component that uses it (up to 0.2). Test and generated code is scaled by 0.2. Checks inside a deleted declaration don't count. `reasons` lists the signals, most significant first.
- **Context regions**: unchanged code that explains a review region, with `relation` and `supports` (the review regions it explains): `definition` (same-type members, and top-level declarations or members of mentioned types, when the name resolves to one declaration; up to 6 per entity), `caller` (usedBy first, then the entity's own component, tests last; up to 5, for interface entities and signature or flag changes), `conformer` (other conformers of a changed protocol, or their implementation of a changed requirement), `override` (overrides of a changed method, and the method a changed override overrides), and `state` (the stored properties of the enclosing type when a body changed). `lines` lists the lines that matter, such as the signature and the referencing lines. Test and generated code gets no context.

## Index mode

Name matching is fast and needs no build, but it guesses: a common member name (`load()`, `id`) counts as a use of every changed declaration with that name in files that mention its type, and a type name declared in two modules isn't resolved. Index mode replaces the guess with the compiler's own answer.

- **Building**: each side's exported tree is built once with indexing on. For a Bazel workspace with targets (`MODULE.bazel` or `WORKSPACE` in the current directory or above it, or else the one below it, such as `ios/` in a monorepo), it's `bazel build <targets> --features=swift.index_while_building --features=swift.use_global_index_store` (`bazelisk` when there's no `bazel`). The targets come from `--index-target`, `index.targets`, or the `top_level_targets` of the rules_xcodeproj `xcodeproj` rule in the workspace's root `BUILD` file, so a repo that runs `bazel run //:xcodeproj` needs no setup. Each build gets a temporary output base that is expunged afterwards; downloads are shared through Bazel's repository cache, and actions through a disk cache in `~/.reviewmap/index/.bazel-disk-cache`. `index.bazelArgs` adds flags such as a `--config`. Otherwise: `xcodebuild build` for the workspace, project, or package (or `--index-project`), with `-destination generic/platform=iOS Simulator` and code signing off, or `swift build --enable-index-store` for a package where there is no Xcode. Builds run outside the target repo, and resolved packages are shared in `~/.reviewmap/index/.packages`. Without `--index-project`, the whole repo is searched (skipping `Pods`, build folders, and the like): a workspace wins over a project, and a project over a `Package.swift`. When there are several, the ones under the directory you run from are preferred, so in a monorepo running from the app's directory picks its project.
- **Cache**: the index store is kept per repo and commit in `~/.reviewmap/index/<repo>/<sha>/`, with the build log. A base shared by several branches is built once, and running again on the same head builds nothing. `--rebuild-index` builds again; the old store stays until the new build succeeds.
- **Reading**: IndexStoreDB, with `libIndexStore` from the same toolchain (`xcrun --find swift`, or `swift` on the `PATH`; `REVIEWMAP_LIBINDEXSTORE` overrides it), gives every reference in a file and the declaration it points at.
- **What it changes**: edge references (named by the referenced top-level declaration, as before), `usedBy` and `dependsOn` (exact, members included), caller context (every reference in any component, instead of usedBy plus a name search in the entity's own component), and definition context (the declarations the changed lines reference). Conformer and override context still come from inheritance clauses.
- **Fallback**: if either side can't be built or read, the language's files are matched by name at both sides, so the two sides never mix methods, and an `index-unavailable` warning gives the reason and the build log. Files the index doesn't cover (not part of the built scheme or targets, for example) are matched by name, with an `index-partial` warning. Test files are matched by name when the scheme doesn't build their targets, without a warning.

To keep it on for a repo, add `index: {enabled: true}` to its `reviewmap.yml`, with `scheme` and `project` if the defaults don't pick the right ones.

## LLM annotator

The LLM only annotates facts the analyzer already produced. It never adds entities, edges, or regions, and it never changes the deterministic scores; its results sit next to them in `llm` fields.

- **Tasks**: give every review and removed region a risk from 0 to 1 and one sentence on why it matters; mark each context region as kept or left out, and rank the kept ones; write a one-line behavior summary for each component and each changed entity; tag review regions that add defensive handling for a state that can't occur, or a speculative abstraction, as removal candidates.
- **Scope**: changed entities outside test components and without `test` or `generated` tags. Cosmetic changes are skipped.
- **Batches**: one per component, split by size (about 60,000 characters of entity material) for large components. The first batch of a component also asks for its summary.
- **Prompt**: per entity, its kind, change, contract flags, signatures, usage, the head code (and base code when it changed), its regions with their deterministic risk and reasons, and the lines of each context region that matter. Declarations longer than 150 lines show their first lines and their regions. `REVIEW.md` from the head of the target repo, if there is one, goes in as domain notes. The prompt ends with a reply template that already holds every id, so the reply only fills in values.
- **Execution**: `claude -p --output-format json --tools "" --no-session-persistence`, or `codex exec --sandbox read-only --output-last-message <file> -`, with the prompt on stdin and `--model` when `--llm-model` is set. Each call runs in an empty temporary directory, so the agent never sees or writes to the target repo.
- **Validation**: the reply must be the template filled in, with the same entities, regions, and context regions, risks in 0 to 1, one-line notes and summaries, removal kinds `defensive` or `speculative`, and a rank from 1 on every kept context region. Text around the JSON, such as a code fence, is ignored. A batch that fails is retried once with the errors; if it fails again, its regions keep only their deterministic scores and an `llm-rejected` warning names the errors.
- **Cache**: one file per entity and one per component summary, keyed by a hash of the prompt version, tool, model, `REVIEW.md`, and everything the prompt says about the entity. A second run only calls the CLI for entities whose material changed.
- **Missing CLI**: the annotator is skipped with an `llm-unavailable` warning, and the model has no `llm` fields.

`scripts/fake-llm.sh` stands in for either CLI in tests and demos: it fills the reply template with canned values picked by a hash of each id. `FAKE_LLM_MODE` makes it wrap the JSON in prose (`prose`), return a risk outside 0 to 1 (`invalid`), exit with an error (`fail`), or return claude's `is_error` result (`error`).

## Viewer

`viewer/` is a React + TypeScript app (Vite, React Flow, elkjs, Shiki). It has three levels, and a breadcrumb (Map › Component › Entity) with back and forward on top.

**Level 1, component map**

- Nodes are components. Split folders are drawn inside their target. A badge shows changed entities and interface changes, and the tint follows `changeScore`. Components that exist on one side only have a dashed border. External packages are small pills with their version change.
- Edges point from the user to the used component. Added edges are green, removed edges red and dashed, changed edges amber, and unchanged edges grey. Line weight follows the reference count.
- By default the map shows changed components and their direct neighbors, without test targets. Toggles show the whole system, tests, and unchanged edges. The layout only changes when the set of visible components changes.
- A target split into folders can be collapsed into one node (drawn as a stack, with the number of components inside) and expanded again, with the arrow button on the node or in the side panel. Edges into a collapsed group are bundled into one arrow per pair of nodes. Above 40 visible components every group starts collapsed; "Collapse groups" and "Expand groups" in the toolbar do all of them. A focus inside a collapsed group opens it.
- Clicking a component focuses it: unrelated nodes and edges dim, and the side panel lists its changed entities. Clicking it again, or "Open interface view", opens level 2. Clicking an edge lists the references that create it, with added and removed symbols marked. Clicking a bundled edge lists the dependencies inside it; picking one opens its group.
- "Show N more neighbors" in the side panel adds a component's hidden neighbors to the map, whatever the scope.
- **Start here** lists the highest-risk entities, each scored by its riskiest region, with changed members folded into their type, and opens that region at level 3. "Review regions by risk" starts at the riskiest region. A model without regions is ranked by contract flags.
- Each component shows a review progress bar.

**Level 2, interface view**

- One component's changed interface entities, grouped by kind. Each shows its head signature with changed tokens highlighted (the base signature is behind a "base" toggle), its contract flags, and Used by and Depends on lists that lead to the code behind them.
- Internal changes are one line each below. Cosmetic, test, and generated changes are behind a count.

**Level 3, implementation view**

- The entity's head code, highlighted. Review regions are tinted, with a label row above each that shows the risk, the reasons, a Note button, and Open. Removed lines are collapsed markers that expand to the base lines; a removed region's label sits on its marker. Code outside regions is folded. A removed entity shows its base code.
- Context regions appear after the region they support as one-line labels in a second color ("caller in Checkout", "definition", "state"). A label expands to the lines that matter, with the rest of the declaration folded, and links to the code.
- Notes attach to a region and show under it.
- Previous and Next step through the component's entities. Changed type names and dependencies in the code are links. Callers in unchanged code open as a code location.
- **Open** opens the file at the line in your working copy, in the editor set with `--editor` (local server only).

**LLM layer**

- When the model has LLM annotations, Start here shows a **Ranking** toggle: Deterministic or LLM. It switches the risk that Start here, region order, `j`/`k`, and the risk badges use. The LLM layer is on by default, and the choice is kept in browser storage.
- With the LLM layer on, entity and component summaries show under their headers (side panel, level 2, level 3). The rest shows on demand: a region's note behind **Why** in its label row, and removal candidates as a tag in the label row and as a list behind their count in the overview. A risk badge that comes from the LLM has an outline, and its tooltip shows both scores.
- Context the LLM left out folds into a "Show N context snippets left out by the LLM" link after the kept ones, which follow the LLM's rank.
- With the LLM layer off, the viewer shows only deterministic facts, as if the annotator hadn't run.
- The overview names the CLI that scored the change and the batches that kept deterministic scores, which open their validation errors.

**Across levels**

- Every entity has a reviewed checkbox at levels 2 and 3 and in the side panel. The overview shows progress and lists notes, with Copy as Markdown and Download for a GitHub review.
- `j` or `]` moves to the next region in risk order, `k` or `[` to the previous one, from any level. Level 3 also has buttons for this.
- With the local server, reviewed marks and notes are saved next to the model, as `change-model.review.json` for `change-model.json`, keyed by head commit. The single-file build keeps them in browser storage.

The focus, including the region, is kept in the URL, so browser back and forward move through it. Escape goes up one level.

To work on the viewer directly:

```sh
cd viewer
npm ci
REVIEWMAP_MODEL=/path/to/change-model.json npm run dev   # serves the model, sources, and Open (REVIEWMAP_EDITOR picks the editor)
npm test                                                  # logic tests against the analyzer fixture
REVIEWMAP_MODEL=/path/to/change-model.json npm run build:single
```

`build:single` writes `dist/index.html`, one self-contained file with the model and the relevant source files embedded, which opens in any browser without a server. Sources are read from the repo at the model's commits (`REVIEWMAP_REPO` overrides the path recorded in the model, and `REVIEWMAP_EMBED_MAX` the 8 MB cap).

The dev server reads file contents with `git show <sha>:<file>` in the repo recorded in the model, so it never touches the working copy. Without a model the page asks for a file, and `?model=<url>` loads one from a URL.

## reviewmap.yml

```yaml
components:            # glob rules; the first match wins and overrides the inferred component
  - name: Checkout
    paths: ["App/Features/Checkout/**"]
    layer: domain      # ui | domain | data | infra
split:
  threshold: 30        # split targets with more source files than this
  maxDepth: 3
exclude: ["**/Vendor/**"]
generated: ["**/*.generated.swift"]   # tagged "generated"
index:                 # index mode; the CLI flags win
  enabled: true
  project: App.xcworkspace
  scheme: App
  destination: "generic/platform=iOS Simulator"
  builder: xcodebuild  # or bazel, swift
  targets: ["//ios:App"]          # Bazel; default: top_level_targets of the xcodeproj rule
  bazelArgs: ["--config=sim"]     # extra bazel build flags
```

## change-model.json

The schema is in `Sources/ReviewMapCore/Model.swift`. Fields worth knowing:

- `version` is 2: contract flags carry their language's prefix. `analyzer` has the version, the resolution mode, and the `languages` in the change; `repo` has `usesMergeBase`.
- Components: `module`, `parent`, `isTest`, `status` (`added`/`removed`), `changedEntities`, `interfaceChanges`.
- Edges: `symbolsAdded`, `symbolsRemoved`, `refCount`. `refs` is capped, with differing symbols listed first. A ref with `line: 0` comes from a manifest.
- Entities: `changes`, `parent` (entity id, which may point to an unchanged declaration that isn't listed), `tags` (`test`, `generated`), and `baseLocation`. Entity kinds also include `file` and `target`.
- `usedBy` and `dependsOn` are `{component, symbol, file, line}` objects rather than entity ids, because the referring declaration usually didn't change and so has no entity.
- Regions: `anchor` (removed regions), and `component` and `lines` (context regions). Region ids are `<entity id>/r<n>` for review and removed regions and `<entity id>/c<n>` for context. A context region's `reasons` holds the qualified name of the declaration shown.
- LLM annotations: review and removed regions get `llm: {risk, note, removal?: {kind, note}}`, and context regions `llm: {keep, rank?}`. Components and entities get `llm: {summary}`. The top-level `llm` records the tool, model, stand-in command, prompt version, and how many batches ran, came from the cache, and were rejected.

Fields that are `null` are omitted. Consumers should ignore fields they don't know.

## Tests

```sh
swift test
```

`Tests/ReviewMapCoreTests/Fixtures/basic` is a small SPM repo with a base and a head tree, with one scenario per contract flag. The test builds a two-commit git repo from it, checks the important facts, and compares the whole output with `expected.json`. `Fixtures/indexed` is a package that builds anywhere; the index tests build it with `swift build`, compare index mode with name matching on a common member name and a type declared in two modules, and check the cache and the fallback. They are skipped when the toolchain has no `libIndexStore`. The SCIP tests decode indexes written field by field, without an indexer. The annotator tests run `scripts/fake-llm.sh` on the basic fixture, cover validation, retries, the cache, and both CLIs, and compare the result with `annotated.json`, which the viewer tests also read. Run `UPDATE_SNAPSHOTS=1 swift test` to accept new snapshots.

## Known limits

- Name-based resolution (the default): member usage (`x.foo`) is matched by name within files that reference the owning type, so common member names (`id`, `name`) can over-count `usedBy` and caller context. Index mode resolves them exactly but needs both sides to build.
- Risk signals are syntactic: a changed line that contains an `if` counts as changed control flow even when only its body changed.
- A declaration that moves between components shows up as removed plus added.
- Files that belong to several Xcode targets are assigned to one, preferring the app target, and a warning gives the count.
- Without `--dump-package`, manifests that build their targets with loops or helper functions are only partly read.
- The annotator has only run against `scripts/fake-llm.sh`, not yet against the real `claude` or `codex` CLI.
