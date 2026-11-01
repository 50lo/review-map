# Review Map

A throwaway prototype that shows a Swift change as structure (components, dependency edges, changed contracts) instead of line diffs. It has two parts joined by one file: an analyzer that reads two git refs and writes `change-model.json`, and a browser viewer that reads it. Progress is tracked in [docs/progress.md](docs/progress.md).

## Run it

Requires the Swift 6.2 toolchain (Xcode 26) on macOS, and Node 20 or later for the viewer. The analyzer also builds and runs on Linux.

```sh
swift build -c release
.build/release/reviewmap /path/to/repo --base main --head feature-x --view
```

That writes `change-model.json` in the current directory, starts the viewer on it, and opens the browser. The first run installs the viewer's npm dependencies. Without `--view` it only writes the file, and `reviewmap view [change-model.json]` opens an existing one. Options:

| Option | Meaning |
| --- | --- |
| `--base`, `--head` | Any git refs. By default the base is the merge-base of the two, which is what a PR shows. |
| `--no-merge-base` | Compare against `--base` directly. |
| `-o <file>` | Output path, or `-` for stdout. |
| `--config <file>` | A `reviewmap.yml`. By default it's read from the head of the repo, if one exists there. |
| `--dump-package` | Evaluate `Package.swift` with `swift package dump-package` instead of parsing it. More exact for computed manifests, but it compiles and runs the manifest. |
| `--max-refs <n>` | References kept per edge (default 50). |
| `--summary` | Print a short summary to stderr. |
| `--view` | Serve the result in the viewer and open the browser. Stop with Ctrl-C. |
| `--port <n>` | Viewer port (default 5173). |

The analyzer never writes to the target repo. Both trees are exported with `git archive` into a temporary directory, which is removed on exit.

## What it extracts

- **Components**: SPM targets (from every `Package.swift`, including local packages), Xcode native targets (with XcodeProj: build-phase files and Xcode 16 synchronized folders), and top-level folders for any remaining files. A target with more than 30 Swift files is split by folder, recursively, up to depth 3. Split folders keep a `parent` pointing to their target. Third-party packages become `external` components.
- **Dependency edges**: `import` statements, target dependencies in manifests, and type-level references, resolved by name against a table of top-level declarations. A reference only counts when the referring file can see the declaring module (same module or imported). Ambiguous names are recorded in `warnings` and not resolved. Each edge is `added`, `removed`, `changed` (the set of referenced symbols changed), or `unchanged`, and keeps its references.
- **Entities**: types, extensions, functions, initializers, properties, enum cases, and typealiases, matched between base and head by component, scope, name, and kind. Overloads are paired by exact signature, then by argument labels. The change kinds are `added`, `removed`, `signature`, `body`, `modifiers`, and `cosmetic` (trivia only). `changes` lists every aspect that changed. A type appears as an entity only when its own header changed or it carries contract flags; its members are reported one by one.
- **Contract flags**: `protocol-requirement-added|removed|changed`, `conformance-added|removed:<P>` (compared per type, across its extensions), `conformance-isolation-changed:<P>`, `access-changed:<a>-><b>`, `async-…`, `throws-…`, `typed-throws-changed`, `mainactor-…`, `nonisolated-…`, `sendable-…`, `kind-changed:class->actor`, `enum-case-added|removed|changed`, `codable-shape`, `swiftdata-model-changed`, `observable-state-changed`, `observable-added|removed`.
- **Non-code contracts**: `Info.plist` (plus `url-schemes-changed`), entitlements, `PrivacyInfo.xcprivacy`, and Core Data models appear as `file` entities. Target build settings appear as `target` entities: Package.swift `swiftSettings`, and Xcode settings such as `SWIFT_DEFAULT_ACTOR_ISOLATION`, `SWIFT_STRICT_CONCURRENCY`, and `SWIFT_VERSION`. Their flags include `default-isolation-changed`, `strict-concurrency-changed`, `swift-features-changed`, `swift-version-changed`, and `deployment-target-changed`.
- **External packages**: `Package.resolved` pins that were added, removed, or bumped.
- **Usage**: `usedBy` lists declarations in other components that reference an entity, and `dependsOn` lists what the entity references in other components. An entity is an interface when it's `public`/`open`/`package`, used from another non-test component, or a requirement or case of an interface type.

Review regions, context regions, and risk scores are not implemented yet, so `regions` is empty.

## Viewer

`viewer/` is a React + TypeScript app (Vite, React Flow, elkjs, Shiki). It has three levels, and a breadcrumb (Map › Component › Entity) with back and forward on top.

**Level 1, component map**

- Nodes are components. Split folders are drawn inside their target. A badge shows changed entities and interface changes, and the tint follows `changeScore`. Components that exist on one side only have a dashed border. External packages are small pills with their version change.
- Edges point from the user to the used component. Added edges are green, removed edges red and dashed, changed edges amber, and unchanged edges grey. Line weight follows the reference count.
- By default the map shows changed components and their direct neighbors, without test targets. Toggles show the whole system, tests, and unchanged edges. The layout only changes when the set of visible components changes.
- Clicking a component focuses it: unrelated nodes and edges dim, and the side panel lists its changed entities. Clicking it again, or "Open interface view", opens level 2. Clicking an edge lists the references that create it, with added and removed symbols marked.
- **Start here** lists the highest-risk regions and opens them at level 3. Until the analyzer scores regions (milestone 4), it ranks changed entities by their contract flags and folds members into their type.

**Level 2, interface view**

- One component's changed interface entities, grouped by kind. Each shows its head signature with changed tokens highlighted (the base signature is behind a "base" toggle), its contract flags, and Used by and Depends on lists that lead to the code behind them.
- Internal changes are one line each below. Cosmetic, test, and generated changes are behind a count.

**Level 3, implementation view**

- The entity's head code, highlighted. Until regions exist, changed lines inside the entity are marked and removed lines are collapsed markers. Unchanged code is folded. A removed entity shows its base code.
- Previous and Next step through the component's entities. Changed type names and dependencies in the code are links. Callers in unchanged code open as a code location.
- **Open in Xcode** runs `xed --line` on the file in your working copy (macOS, local server only).

The focus is kept in the URL, so browser back and forward move through it. Escape goes up one level.

To work on the viewer directly:

```sh
cd viewer
npm ci
REVIEWMAP_MODEL=/path/to/change-model.json npm run dev   # serves the model, sources, and Open in Xcode
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
  threshold: 30        # split targets with more Swift files than this
  maxDepth: 3
exclude: ["**/Vendor/**"]
generated: ["**/*.generated.swift"]   # tagged "generated"
```

## change-model.json

The schema is in `Sources/ReviewMapCore/Model.swift`. It follows the sketch in the brief, with these additions:

- `analyzer` (version, resolution mode) and `repo.usesMergeBase`.
- Components: `module`, `parent`, `isTest`, `status` (`added`/`removed`), `changedEntities`, `interfaceChanges`.
- Edges: `symbolsAdded`, `symbolsRemoved`, `refCount`. `refs` is capped, with differing symbols listed first. A ref with `line: 0` comes from a manifest.
- Entities: `changes`, `parent` (entity id, which may point to an unchanged declaration that isn't listed), `tags` (`test`, `generated`), and `baseLocation`. Entity kinds also include `file` and `target`.
- `usedBy` and `dependsOn` are `{component, symbol, file, line}` objects rather than entity ids, because the referring declaration usually didn't change and so has no entity.

Fields that are `null` are omitted. Consumers should ignore fields they don't know.

## Tests

```sh
swift test
```

`Tests/ReviewMapCoreTests/Fixtures/basic` is a small SPM repo with a base and a head tree, with one scenario per contract flag. The test builds a two-commit git repo from it, checks the important facts, and compares the whole output with `expected.json`. Run `UPDATE_SNAPSHOTS=1 swift test` to accept a new snapshot.

## Known limits

- Name-based resolution: member usage (`x.foo`) is matched by name within files that reference the owning type, so common member names (`id`, `name`) can over-count `usedBy`. An exact index mode (IndexStoreDB) is planned.
- A declaration that moves between components shows up as removed plus added.
- Files that belong to several Xcode targets are assigned to one, preferring the app target, and a warning gives the count.
- Without `--dump-package`, manifests that build their targets with loops or helper functions are only partly read.
