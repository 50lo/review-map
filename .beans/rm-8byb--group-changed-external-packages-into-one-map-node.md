---
# rm-8byb
title: Group changed external packages into one map node
status: todo
type: task
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T09:57:22Z
parent: rm-w7ge
---

## What

Stop the external packages that a change adds, removes or bumps from crowding the map. Today each one is its own node with its own finding badge.

**Observed** in a review of base `0cd5916` against head `0e57fa4` of this repository:

- The map shows nine external package nodes in a grid: `@tauri-apps/cli`, `@types/semver`, `apple_support`, `aspect_rules_js`, `aspect_rules_ts`, `bazel_lib`, `bazel_skylib`, `rules_rust`, `typescript`. They take about a third of the canvas.
- Seven of them carry a "1 finding" badge: all except the removed `@tauri-apps/cli` and the bumped `typescript`. These are `new-external` findings.
- The check in `crates/core/src/analyze/checks.rs` (around line 507) raises one `new-external` finding per added package. Its message names the components that now depend on it. Its severity is `medium` when a lockfile pins the package, else `low`, and `low` when only tests use it. Its anchors are the edges from those users plus the package's component.
- The green "added" border already says the package is new, so the badge mostly repeats it. The real findings on the map are drowned out by seven copies of "you added a dependency".

**Do this (approach A, no rule change):** on the map, gather the changed external packages into one group node, "Dependencies", collapsed by default.

- The collapsed node shows the number of packages by change, e.g. "6 added · 1 removed · 1 bumped", and one finding badge rolled up over its contents. That rollup is the existing behaviour for collapsed groups: `findingCounts` in `app/src/findings.ts` counts a hidden component's findings on the outermost collapsed group.
- Edges from components to packages go to the group while it is collapsed. This is the existing collapse behaviour in `app/src/graph.ts`.
- Expanding it shows the package nodes as today.
- Selecting it opens a panel that lists every package with its change (added, removed, or the version range) and its findings, each linking to the package's own panel.

The group is a view-only component made in the UI's index (`buildIndex` in `app/src/graph.ts`). Give it an id that can't clash with a real component, e.g. `group:external`. The report and the check stay as they are.

**Don't do without a decision (approach B):** stop showing `new-external` as a finding badge, or stop raising it per package. This changes what the check means. It needs a proposed decision (`statute decide`) and the user's approval before any code changes. If you think B is better after A lands, propose it as a separate bean.

## Why

Findings are the map's strongest signal of where to look. When most of them say what the node's border already says, the reviewer learns to ignore the badges, including the ones that matter (cycles, layering, unused API). The grid of disconnected package nodes also takes space from the components under review.

## Where

- `app/src/graph.ts`: `buildIndex`, `visible`, `defaultCollapsed`, `collapse`, `rollup`, `externalChangeOf`.
- `app/src/findings.ts`: `findingCounts`, `findingsForComponent`.
- `app/src/MapView.tsx`: `GroupNode` and `ComponentNode` rendering for the new group.
- `app/src/Sidebar.tsx`: a panel for the group, or `ComponentPanel` extended for it.
- `app/src/layout.ts` if the group needs placement hints.

## Acceptance criteria

- [ ] On the review above, the map shows one collapsed "Dependencies" node in place of the nodes for every changed external package in the report (`externalDeps` in the `--report` output). It says how many packages changed by kind and shows one finding badge with the total. External packages that didn't change but are drawn because a changed edge reaches them (`indexstore-db` and `swift-syntax` in this review) stay outside the group.
- [ ] Expanding it shows each package as today. Collapsing it again works, and so does the toolbar's "Collapse groups" / "Expand groups".
- [ ] Selecting the group lists every changed package, its change and its findings. Each package opens its own panel in one click.
- [ ] Findings totals in the Overview and the findings lists are unchanged. No finding is lost or counted twice.
- [ ] When a focus inside the group is restored (back/forward, URL hash, report refinement), the group expands to reveal it (`revealFocus`).
- [ ] Unit tests in `app/src/graph.test.ts` (there is no `findings.test.ts` yet; add one if the tests fit there better) for the grouping, rollup and reveal.
- [ ] `bazel test //app:test` passes.

## Dependencies and constraints

- Rule CORE-005 "Every finding points at something on the map" (`statute/rules/core.md`): every finding must stay reachable from what it is anchored to, including when its package sits inside the collapsed group. Run `statute show` on the files you touch first.
- Approach B needs a statute decision and the user's approval, as above.
- Epic: UI improvements (rm-w7ge).
