---
# rm-t9hw
title: Yarn Berry support
status: in-progress
type: epic
priority: normal
created_at: 2026-11-18T21:10:16Z
updated_at: 2026-11-18T21:44:52Z
---

Index TypeScript in Yarn Berry (Yarn 2, 3 and 4) projects, which today end syntax-only with the warning "Yarn Berry support comes later".

## Why

Review Map (the Rust core in `crates/core`) resolves TypeScript references through `scip-typescript`, which needs `node_modules` for third-party types and for workspace packages to find each other. For Yarn Classic roots the app runs `yarn install` with scripts off in its own copy of the revision (the app-owned tree, `<cache>/bazel/<repo>/<side>/tree`), never in the reviewed repository (CORE-002 in `statute/rules/core.md`). Berry roots are detected (`Manager::YarnBerry` in `crates/core/src/lang/typescript/project.rs`) but refused by `unsupported` in `crates/core/src/index/typescript.rs`. Workspace components, import resolution and Berry lockfile pins already work; only the install is missing.

## Decisions (planned 2026-11-19)

- Install with the project's own Yarn release and **force the `node-modules` linker** (`YARN_NODE_LINKER=node-modules`) whatever the project's `.yarnrc.yml` sets (`pnp`, `pnpm` or `node-modules`). `scip-typescript` uses its own unpatched TypeScript, which cannot resolve through Plug'n'Play, and a PnP install has no `node_modules` in which workspace packages link to each other. With real `node_modules`, everything after the install is the existing Yarn Classic path. The linker does not change the lockfile.
- Install scripts stay off, as for Classic.
- pnpm, npm and Bun stay unsupported.
- Index mode executes the project's committed Yarn release (`yarnPath`) and Yarn plugins. This is accepted, as Bazel actions and Yarn Classic's `yarn-path` already are; the README says so.

## Facts checked on 2026-11-19

- Yarn docs (yarnpkg.com/cli/install, /configuration/yarnrc): `--immutable` aborts if the lockfile would change; `--mode=skip-build` runs no build scripts; a setting can be given as a `YARN_<SNAKE_CASE>` environment variable, which overrides the rc files; `nodeLinker` takes `pnp`, `pnpm`, `node-modules`.
- npm has `@yarnpkg/cli-dist` (4.18.1) with a `yarn` bin. Corepack is bundled with Node.js up to, not including, 25.0.0.
- The Mac mini has Node.js 24 with corepack and no global Yarn.

## Order

1. rm-wb96: one install seam per package manager in the TypeScript index (no behaviour change).
2. rm-xt4l: read what a Berry root needs for an install.
3. rm-1l2w: the Berry install, fixture, tests and docs.

## Done when

A review of a Yarn Berry workspace, whatever its `nodeLinker`, ends with TypeScript resolution `index`, and the README no longer lists Berry as unsupported.
