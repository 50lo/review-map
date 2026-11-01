# Review Map

A throwaway prototype that shows a Swift change as structure (components, dependency edges, changed contracts) instead of line diffs. It has two parts joined by one file: an analyzer that reads two git refs and writes `change-model.json`, and a browser viewer that reads it. Progress is tracked in [docs/progress.md](docs/progress.md).

## Run it

Requires the Swift 6.2 toolchain (Xcode 26) on macOS. It also builds and runs on Linux.

```sh
swift build -c release
.build/release/reviewmap /path/to/repo --base main --head feature-x --summary
```

That writes `change-model.json` in the current directory. Options:

| Option | Meaning |
| --- | --- |
| `--base`, `--head` | Any git refs. By default the base is the merge-base of the two, which is what a PR shows. |
| `--no-merge-base` | Compare against `--base` directly. |
| `-o <file>` | Output path, or `-` for stdout. |
| `--config <file>` | A `reviewmap.yml`. By default it's read from the head of the repo, if one exists there. |
| `--dump-package` | Evaluate `Package.swift` with `swift package dump-package` instead of parsing it. More exact for computed manifests, but it compiles and runs the manifest. |
| `--max-refs <n>` | References kept per edge (default 50). |
| `--summary` | Print a short summary to stderr. |

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
