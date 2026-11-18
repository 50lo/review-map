---
# rm-1l2w
title: Index TypeScript in Yarn Berry projects
status: completed
type: feature
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:58:09Z
parent: rm-t9hw
blocked_by:
    - rm-wb96
    - rm-xt4l
---

Install a Yarn Berry (Yarn 2, 3, 4) project's dependencies in the app-owned tree and index its TypeScript with `scip-typescript`, as Yarn Classic projects are indexed today. Part of the Yarn Berry epic (rm-t9hw).

## Why

A Berry root ends syntax-only today: `unsupported` in `crates/core/src/index/typescript.rs` returns "it is a Yarn Berry (v2 or later) project …; Yarn Berry support comes later". Only the install is missing: once `node_modules` exists, the Classic path (run `scip-typescript`, resolve its SCIP index, leave out files with unresolved imports) works as it is.

## What

1. Add `Install::YarnBerry { version: String, yarn_path: Option<String> }` to the `Install` enum introduced by rm-wb96 in `crates/core/src/index/typescript.rs`, with its install function. It runs, in the root's directory inside the app-owned tree (the app's copy of the revision, never the reviewed repository; CORE-002 in `statute/rules/core.md`):

   ```text
   <yarn> install --immutable --mode=skip-build
     env YARN_NODE_LINKER=node-modules YARN_ENABLE_SCRIPTS=false YARN_ENABLE_GLOBAL_CACHE=true
         YARN_ENABLE_TELEMETRY=false COREPACK_ENABLE_DOWNLOAD_PROMPT=0  PATH=<tools::node_path>
   ```

   - **Why `node-modules` is forced:** `scip-typescript` uses its own unpatched TypeScript, which cannot resolve through Plug'n'Play, and a PnP install has no `node_modules` in which workspace packages link to each other. Forcing the linker gives the Classic layout for every `nodeLinker` setting and does not change the lockfile.
   - `--immutable` only when the root has a lockfile. Yarn 2 has no `--mode`; it gets `--skip-builds`.
   - **Which Yarn**, in order: the release the project commits (`yarn_path` from rm-xt4l), run as `node <tree>/<yarn_path>`; `corepack yarn@<version>`; `npx --yes @yarnpkg/cli-dist@<version>` (Node.js 25 and later ship no corepack). `version` is the `packageManager` pin; without one, `lock_version >= 8` picks a pinned Yarn 4 constant and anything lower a pinned Yarn 3 constant, both declared next to `YARN_CLASSIC`. An installed global `yarn` is not used: a wrong major rewrites the lockfile.
   - Hold the `NODE_TOOLS` mutex while Yarn runs, as the Classic install does.
2. Generalize `restore_tracked` in the same file: restore every tracked file under the root that the install changed **or removed** among `package.json`, `yarn.lock`, `.pnp.cjs`, `.pnp.loader.mjs`, `.yarnrc.yml`. (With the `node-modules` linker Yarn deletes a committed `.pnp.cjs`; the tree's manifest trusts that tracked files are as written.)
3. Remove Berry from `unsupported`, and choose the `Install` from `root.manager` in `Session::index_typescript` (`crates/core/src/session.rs`). The cache key's manager part for Berry is `yarn-berry <version>`.
4. Fixture `crates/core/tests/fixtures/ts-berry/{base,head}`: the `ts-yarn` fixture (three workspace packages, no third-party dependency) with `"packageManager": "yarn@4.x.y"`, a Berry `yarn.lock`, `workspace:*` dependencies, and a `.yarnrc.yml` that sets no `nodeLinker`, so the project's own linker is PnP.
5. Docs: README.md ("Languages" table, and the sentence "Yarn Berry is detected and reported as not supported yet"), the scope lines of `docs/rebuild-phase1-proposal.md` (with the date), the test list in `docs/rebuild-build.md`. Add to the README that index mode runs the project's committed Yarn release and plugins.

## Acceptance criteria

- New test `yarn_berry_workspace_index` in `crates/core/tests/typescript_fixtures.rs` on `ts-berry`: TypeScript resolution is `index`; `Store.load()` is used by the app's caller and `Cache.load()` by none, as in `yarn_workspace_index`; the reviewed repository, `.git` included, is unchanged by size and modification time (the existing `snapshot` helper); a second run is a cache hit. It returns early, saying why, without Node.js.
- After the install, every tracked file under the root in the app-owned tree has its blob's content.
- `yarn_berry_is_reported_not_indexed` is replaced by a test that a Berry root with no Node.js (`REVIEWMAP_NODE` naming nothing) ends syntax-only with the Node.js reason. `a_project_that_is_berry_at_one_side_is_indexed_at_neither` becomes: a project that is Classic at base and Berry at head is indexed at both sides. `other_package_managers_are_not_indexed` and `unsupported_managers` (minus its Berry assertion) pass.
- Checked by hand, with the result written into this bean: `--immutable` under `YARN_NODE_LINKER=node-modules` on a PnP project and on a zero-install project (committed `.yarn/cache` and `.pnp.cjs`), and the `__metadata.version` to Yarn major mapping. If `--immutable` fails there, the install retries without it and restores the tracked files.
- `bazel test //...` passes, and the Statute `change` skill has been run (AGENTS.md).

## Dependencies and constraints

- Blocked by rm-wb96 (the `Install` seam) and rm-xt4l (`yarn_path`, `lock_version`).
- Install scripts never run. A failed install does not stop indexing: it adds the existing `index-partial` warning and the index is not cached.
- The first run downloads Yarn and scip-typescript; the Mac mini has Node.js 24 with corepack and no global Yarn.

## Checked by hand (2026-11-19)

Node.js 24.22.2, corepack 0.36.0, macOS. A copy of the ts-yarn fixture as a Yarn workspace with `workspace:*` dependencies and one third-party package (is-number 7.0.0), each project in its own git repository in a temporary directory outside this one. Install command as in What 1: `install --immutable --mode=skip-build` with `YARN_NODE_LINKER=node-modules YARN_ENABLE_SCRIPTS=false YARN_ENABLE_GLOBAL_CACHE=true YARN_ENABLE_TELEMETRY=false`.

- **PnP project** (Yarn 4.18.1 pinned, `.yarnrc.yml` without nodeLinker, `.pnp.cjs` and `.yarn/` not committed): exit 0. `node_modules/@demo/{app,lib,proto}` are links to the packages, `node_modules/is-number` is installed. No tracked file changed.
- **Zero-install project** (`enableGlobalCache: false`, `.yarn/cache/*.zip` and `.pnp.cjs` committed): exit 0, same `node_modules`. Yarn **deleted the committed `.pnp.cjs`**, so `restore_tracked` must restore removed files, not only changed ones. Nothing was added to `.yarn/cache`.
- **`__metadata.version` by Yarn release** (lockfile written by a fresh install): 2.4.3 → 4; 3.1.1 → 5; 3.2.4 and 3.8.7 → 6; 4.0.0 and 4.5.3 → 8; 4.18.1 → 10. 3.0.2 crashes on Node.js 24. The version follows the minor release, not the major.
- **A lockfile in another format than the running Yarn writes fails `--immutable`** (YN0028, "The lockfile would have been modified"): a version 4 or 5 lockfile under 3.8.7, and a version 8 lockfile under 4.18.1. A version 6 lockfile under 3.8.7 passes. This only matters for a root with neither a `packageManager` pin nor a committed `yarnPath`, which falls back to the constants (`YARN_4` = yarn@4.18.1 for lock_version >= 8, `YARN_3` = yarn@3.8.7 below).
- **Without `--immutable`** (and `YARN_ENABLE_IMMUTABLE_INSTALLS=false`, which Berry otherwise turns on in CI) the same installs pass. Yarn 4.18.1 then rewrites `yarn.lock` (the format version) and adds `packageManager` to the root `package.json` ("YN0087 Migrated your project to the latest Yarn version"); `.yarnrc.yml` is untouched. Both are tracked files that `restore_tracked` puts back.

So the retry is implemented: when a root with a lockfile fails `--immutable`, the install runs once more without it, under the same NODE_TOOLS lock, and the tracked files are restored after the last attempt. The log says that it retried.

Also checked: Yarn 2.4.3 accepts the same environment with `--skip-builds` in place of `--mode=skip-build` (exit 0, node_modules laid out; a version 4 lockfile stays unchanged under `--immutable`). The ts-berry fixture's `yarn.lock` (version 10) and its Yarn-formatted `package.json` files were written by running `corepack yarn@4.18.1 install --mode=skip-build` once in a temporary copy.

Also checked: Yarn 2.4.3 committed as `.yarn/releases/yarn-berry.cjs` (the name `yarn set version berry` used in the Yarn 2 days, in projects that also predate `packageManager`) rejects `--mode=skip-build` ("Invalid option name"). The file name names no release, so the install asks the release itself (`<yarn> --version`) and passes `--skip-builds` to Yarn 2; only when that fails does it fall back to the file name and the version.
