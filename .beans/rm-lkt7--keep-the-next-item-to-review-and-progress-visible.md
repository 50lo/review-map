---
# rm-lkt7
title: Keep the next item to review and progress visible at every level
status: completed
type: task
priority: normal
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T11:31:23Z
parent: rm-w7ge
---

## What

Keep "what to review next" and review progress visible at every level of the app. Today they disappear as soon as the reviewer selects anything.

Today:

- The Overview sidebar (`Overview` in `app/src/Sidebar.tsx`) shows these, but only when nothing is selected:
  - "Start here" with the primary button "Review N regions by risk ›"
  - the hint "or press j and k"
  - the "Progress" bar ("X of Y review items reviewed")
- Once a component, edge or bundle is selected, the sidebar shows that item's panel and none of the above.
- The keys j/] and k/[ still work everywhere (`App.tsx`, around line 304). But nothing on screen says so, or says where they lead.
- The review item page (`ReviewItemPageInner` in `app/src/Pages.tsx`, around line 454) already has previous/next buttons and a position (`regionPosition`), but only on that page.

Add a small, always-visible "next" control to the toolbar row in `App.tsx` (the row with the back/forward buttons and breadcrumbs, `nav.crumbs`), on the right side, at every level:

- **On the map level** (no selection, or a component, edge or bundle selected), show "Next: `<review item name>` ›" and a compact progress indicator, "12/30 reviewed". Clicking Next or pressing j opens the first region in risk order whose review item isn't marked reviewed.
- **On a review item page**, show "Region k of N" with ‹ and › buttons, using today's semantics (the next or previous region in risk order). The progress indicator stays.
- **When all review items are reviewed**, show "All N reviewed" and no Next.
- **When the report has no risk regions** (`index.riskOrder` is empty), hide the control.

Proposed contract: a new pure function in `app/src/graph.ts`, `nextUnreviewed(index: Index, reviewed: Record<string, boolean>): Focus`. It returns `{ type: "reviewItem", id, region }` for the first region in `index.riskOrder` whose review item isn't in `reviewed`, or `null` when there is none. j/] on a non-review-item focus uses it too. Today j goes to the first region in risk order (`stepRegion` with a non-review-item focus); with this change it skips what is already reviewed. k/[ keeps its current behaviour.

Progress uses the same numbers as the Overview's "Progress" section: review items that aren't low risk (`isLowRisk`) and how many of them are reviewed (`useReview().reviewed`). The number of regions and the number of review items are different counts, so the labels must say which one they count.

## Why

The phase-1 proposal (`docs/rebuild-phase1-proposal.md`) requires risk ordering and reviewed marks in the review flow. The reviewer's main question is "what do I look at next?", and the only answer is in a panel that goes away the moment they start exploring the map. After clicking around, they must clear the selection to find their place again, or remember j and k.

## Where

- `app/src/App.tsx`: toolbar markup, the keyboard handler.
- `app/src/graph.ts`: `stepRegion`, `regionPosition`, `index.riskOrder`, the new `nextUnreviewed`.
- `app/src/review.ts`: `useReview` (reviewed state).
- `app/src/Sidebar.tsx`: `Overview` (can keep its "Start here" list; the button can call the same function).
- `app/src/Pages.tsx`: the review item page's existing previous/next. Avoid two competing sets of buttons on that page. Either keep the page's own and show only progress in the toolbar there, or move them to the toolbar.
- `app/src/styles.css`.

## Acceptance criteria

- [x] With any selection on the map level, the toolbar shows the next unreviewed review item and progress. Clicking Next opens that review item at its riskiest unreviewed region.
- [x] On a review item page, the toolbar or page shows "Region k of N" with working previous and next, and there is only one set of these buttons on screen.
- [x] Marking a review item reviewed updates progress and the next target immediately.
- [x] "All N reviewed" shows when everything is reviewed. The control is hidden when `riskOrder` is empty.
- [x] j/] from the map goes to the first unreviewed region. k/[ is unchanged. The hint for the keys is visible in a tooltip on the Next button.
- [x] Unit tests for `nextUnreviewed` in `app/src/graph.test.ts`: none reviewed, some reviewed, all reviewed, empty `riskOrder`.
- [x] `bazel test //app:test` passes.

## Dependencies and constraints

- Keep the selected review item, notes and reviewed state when the report is refined during analysis. The proposal requires this, and `carryFocus` in `graph.ts` does it today. The next target must be recomputed from the refined report.
- The toolbar row also holds the map options ("Show", "Tests", "Unchanged edges", "Collapse groups"). The row must not wrap at a window width of 1100 px.
- Epic: UI improvements (rm-w7ge).


## Summary of Changes

- `app/src/graph.ts`: new `nextUnreviewed(index, reviewed): Focus`, which is the first region in `index.riskOrder` whose review item isn't reviewed, or `null`. Also new `reviewProgress(index, reviewed): { done, total }`, which counts review items that aren't low risk (`isLowRisk`). The Overview's Progress section and the toolbar both use it, so their numbers can't differ.
- `app/src/App.tsx`: new `NextControl` at the right end of the toolbar row (`.topbar`).
  - **Any focus that isn't a review item** (the map with or without a component, edge or bundle selected, interface pages, code locations): it shows "Next: <review item> ›" and "X/Y reviewed". The tooltip on Next gives the full name and the keys (j next region, k previous region). The tooltip on the progress says it counts review items and that tests, generated code and cosmetic changes aren't counted.
  - **A review item page**: it shows ‹ "Region k of N" › and the progress. Without a region in focus it shows "N regions", as the page did before.
  - **Everything reviewed**: it shows "All N reviewed" and no Next.
  - **No risk regions** (`riskOrder` empty): the control isn't rendered.
  - The target is computed in render from `index` and the reviewed marks. A refined report therefore recomputes it, and `carryFocus` is untouched.
- Keys: j/] on a review item focus behave as before (`stepRegion`). Anywhere else they go to `nextUnreviewed`. Once everything in risk order is reviewed, they fall back to the riskiest region (`stepRegion(index, focus, 1)`), so j still does something. k/[ are unchanged. The key handler now depends on the reviewed marks, so j sees a mark as soon as it is made.
- `app/src/Pages.tsx`: the review item page's own region stepper was removed. The toolbar has the only region ‹/›. The page keeps its "Review item k of N" stepper, which steps through the component's review items in interface-view order, a different list.
- `app/src/Sidebar.tsx`: the Overview's "Review N regions by risk ›" button goes to the same target as j (the first unreviewed region). The Overview uses `reviewProgress`.
- `app/src/styles.css`:
  - Styles for the control.
  - `.crumbs` flex-basis went from 260px to 120px, so the row doesn't wrap at 1100 px.
  - The back and forward buttons and the "Map" crumb no longer shrink. A long trail is cut with an ellipsis instead.
- Tests in `app/src/graph.test.ts`:
  - `nextUnreviewed`: none reviewed, some reviewed, all reviewed, empty `riskOrder`.
  - `reviewProgress`: low-risk items aren't counted.

### What was checked, and where

- `bazel test //app:test` passes (140 tests), and the `//app:ts` type check passes.
- **Where the visual check ran.** It was done in the dev preview (`bazel run //app:dev`), not in the bundled app.
  - Report: 0cd5916..0e57fa4 of this repo, the one written for rm-mgz2.
  - Window: 1100 × 760, light and dark.
- **One row at 1100 px.** All toolbar children are on one row in every case checked:
  - the map with no selection;
  - a component selected;
  - the longest changed edge selected, with "Whole system" and "Expand groups" showing (the widest case);
  - a review item page.
- **Clicking Next** opened the riskiest unreviewed region.
- **Marking an item reviewed** changed "0/1503" to "1/1503" at once.
- **Region stepper.** › went to Region 2. ‹ went back to Region 1, and ‹ is disabled there.
- **Next skips reviewed items.** With a component selected, Next named the next unreviewed item.
- **Keys.** j from the map skipped the reviewed item. k from the map went to Region 1503 of 1503, as before.
- **All reviewed.** With every item marked reviewed (seeded in the dev mock's storage), the toolbar showed "All 1503 reviewed" with no Next, and j went to Region 1.
- **No risk regions.** With a copy of the report that has no regions, the control wasn't rendered.
- **Not checked:**
  - the bundled app;
  - a refined report arriving while the app is open (the dev preview can't show one).
- Screenshots: `rm-lkt7-screenshots/` in the side-session notes folder of the session that started this work.
