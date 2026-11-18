---
# rm-9zgs
title: A directory that moved from SwiftPM to Bazel shows as two changed components
status: todo
type: bug
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T09:57:22Z
parent: rm-w7ge
---

## What

A directory whose build definition changed kind is shown as two components with the same name, one removed and one new. Each one counts every review item inside it as changed, although its sources didn't change.

**Observed** (review of base `0cd5916`, branch `rebuild-tauri-app-and-indexing`, against head `0e57fa4`, the commit "Review CORE-002 and CORE-003 after the supertype change", in this repository; screenshot of 2026-11-16, taken during the "Querying the build graph" stage):

- The map shows a group `helper` tagged "removed" with "197 changed" and a red dashed border.
- Next to it is a second `helper` tagged "new" with "197 changed" and a green dashed border.
- Both have the Swift icon and edges to `indexstore-db` and `swift-syntax`.
- `git diff --stat 0cd5916...0e57fa4 -- helper` shows that only these files changed:
  - `helper/Package.swift` and `helper/Package.resolved` were deleted
  - `helper/BUILD.bazel` was added

  None of the Swift sources under `helper/` changed. The directory moved from SwiftPM to Bazel.
- So at base the directory is most likely a SwiftPM target and at head a Bazel package. The two get different component ids, so one is "removed", the other "added", and each one's review items count as changed. This explanation is not verified yet.

**Expected:**

- One `helper` component, marked as having a changed build definition, e.g. "build changed: SwiftPM → Bazel".
- Review items for unchanged sources aren't counted as changed.
- The build files' own changes are shown as what changed.

At minimum, two components that share a short name must be told apart on the map, e.g. "helper (SwiftPM)" vs "helper (Bazel)", or by path.

**Steps to reproduce:**

1. In a clone of this repository, run:

   ```sh
   reviewmap . --base 0cd5916 --head 0e57fa4 --report /tmp/helper.json
   ```

   Use the `reviewmap` from the bundle built by `scripts/build-app.sh`, or `~/.local/bin/reviewmap` after `scripts/build-app.sh --install`. The merge-base of the two commits is `0cd5916` itself, so the default merge-base comparison is the same change.
2. Look at `components` in `/tmp/helper.json` for entries named `helper`: their `id`, `kind`, `status` and `changedReviewItems`.
3. Also open the same review in the app and check whether the two nodes are still there after the analysis completes, not only during the preliminary stage.

Record what you find in this bean before fixing anything. If the final report shows only one `helper`, the bug is limited to the preliminary view. Say so, and fix it there.

## Why

The reviewer sees two copies of the same name, 394 "changed" review items that need no review, and a removed component that wasn't removed. The noise hides the real changes. It also undermines trust in the change counts, which drive the "Start here" ranking and the change score tint. CORE-006 ("Formatting-only changes ask for no review") is in the same spirit: unchanged code should not ask for review.

## Where

- Component identity across base and head in the Rust core, under `crates/core/src/analyze/`. `finish.rs` sets component `status` and computes `changedReviewItems` and `changeScore`. Find where SwiftPM and Bazel components are created for each side and where base and head components are matched.
- `app/src/graph.ts`: `shortName`, if names need disambiguation on the map.
- `app/src/MapView.tsx`: node labels.

## Acceptance criteria

- [ ] The investigation result (which ids, kinds and statuses the two `helper` components have, preliminary and final) is recorded in this bean.
- [ ] On the review above, the final map shows one `helper` component whose review items are not counted as changed, or at least as changed only through the build files. The build-definition change is visible on it or in its panel.
- [ ] Wherever two drawn components share a short name, their labels differ.
- [ ] A Rust test with a small fixture (a directory with `Package.swift` at base and `BUILD.bazel` at head, same sources) asserts one component and zero changed review items for the unchanged sources.
- [ ] `bazel test //...` passes, and `statute check` reports no findings.

## Dependencies and constraints

- Must not break CORE-001 to CORE-006 (`statute/rules/core.md`). Run `statute show` on the files you touch first. If matching components across sides needs a rule (for example "a directory's component keeps its identity when its build system changes"), propose it with `statute decide` and get the user's approval.
- Keep configured target identity separate from language packages and lexical scope. `docs/rebuild-phase1-proposal.md` requires this, including sources shared by several targets. Don't merge components just because their names match: match them by directory and sources.
- Epic: UI improvements (rm-w7ge).
