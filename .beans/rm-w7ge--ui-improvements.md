---
# rm-w7ge
title: UI improvements
status: todo
type: epic
created_at: 2026-11-16T09:53:56Z
updated_at: 2026-11-16T09:53:56Z
---

## What

Make the Review Map app (the Tauri 2 app with the React UI in `app/src/`) easier to understand, navigate and use. The work comes from a review of the app on 2026-11-16 using a screenshot of a running review (base `rebuild-tauri-app-and-indexing`, head `claude/core003-supertypes-13ed1f`, taken during the "Querying the build graph" stage with an external package, `@tauri-apps/cli`, selected on the map). The review found that the map shows too many competing signals and the screen doesn't tell the reviewer what to do next.

The child tasks cover:

- dimming that leaves the brightest marks bright
- a status bar that says the same thing several times
- validation tools mixed in with review controls
- the next step to review that vanishes once anything is selected
- per-package findings that crowd the map
- a nearly empty external-package panel
- two components named `helper` that are really one directory whose build files changed
- a legend that is visible only in the Overview sidebar

Four ideas from the same review were left out on purpose and are not part of this epic:

- Finding badges reuse the change colours (`--removed` red, `--changed` orange).
- The floating note with the counts of hidden unchanged and test components covers the top-left of the map and repeats the Tests checkbox.
- The toolbar shows the base and head branch names without labels or a repository name.
- External packages have no edges to the components that declare them.

## Why

The product's value is showing a change as structure instead of line diffs (see `README.md` and `docs/rebuild-phase1-proposal.md`). If the reviewer can't tell at a glance what is selected, how complete the analysis is, and what to review next, the map adds work instead of saving it.

## Where

- `app/src/MapView.tsx`: the map's nodes, edges and badges.
- `app/src/Shell.tsx`: the start screen and the status bar.
- `app/src/App.tsx`: the toolbar, breadcrumbs, map options, keyboard navigation and the indexed/name-based comparison state.
- `app/src/Sidebar.tsx`: the Overview, component, edge and bundle panels.
- `app/src/Pages.tsx`: the interface and review item pages.
- `app/src/graph.ts` and `app/src/findings.ts`: view logic with unit tests.
- `app/src/styles.css`.
- `app/src-tauri/src/lib.rs`: the native menu.
- One task touches the Rust core in `crates/core/src/`.

## Child tasks

Suggested order: rm-6cla before rm-b5d2 (both edit the dim CSS), and rm-kifb before rm-mgz2 (both edit `StatusBar`). The rest are independent.

- rm-6cla: Dim every mark outside the map selection (bug)
- rm-mgz2: Collapse the status bar into one line with a single coverage chip
- rm-kifb: Move the comparison toggle and New review into the app menu
- rm-lkt7: Keep the next item to review and progress visible at every level
- rm-8byb: Group changed external packages into one map node
- rm-xn0c: Show where an external package is declared and who uses it
- rm-9zgs: A directory that moved from SwiftPM to Bazel shows as two changed components (bug)
- rm-b5d2: Make the map legend reachable from the map, and dimmed text readable

## Acceptance criteria

- [ ] Every child task is completed or scrapped with a reason.
- [ ] `bazel test //...` passes.
- [ ] The app built with `scripts/build-app.sh` shows the changes on a real review.

## Dependencies and constraints

- Preserve the review flow that `docs/rebuild-phase1-proposal.md` requires: Map → Component → Review item, code context, findings, risk ordering, notes and reviewed marks. Keep the visual layout. The app stays a focused review tool, not an IDE.
- Keep the analysis coverage information that rule CORE-003 (`statute/rules/core.md`) requires the report to state: preliminary, syntax-only, partial index, and held-back checks. Don't drop it from the screen.
- Statute workflow (`AGENTS.md`): run `statute show` on the files a task touches before changing them, and run the `change` skill before declaring a task done. A change to an agreed rule needs a proposed decision (`statute decide`) and the user's approval.
- To check UI changes without the app window, see `docs/rebuild-build.md`: `REVIEWMAP_REPORT=<report.json> bazel run //app:dev` serves the UI over a saved report. It can't show the running, pending or cancelled states.
