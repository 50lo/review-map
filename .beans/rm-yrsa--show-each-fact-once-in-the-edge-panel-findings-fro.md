---
# rm-yrsa
title: 'Show each fact once in the edge panel: findings from the link''s point of view'
status: todo
type: task
tags:
    - ui
created_at: 2026-11-16T20:46:11Z
updated_at: 2026-11-16T20:46:11Z
parent: rm-w7ge
---

## What

Stop the dependency (edge) panel in the Review Map app's right sidebar from repeating itself. Show each fact once, and show findings from the point of view of the link the panel is about.

The panel is `EdgePanel` in `app/src/Sidebar.tsx` (around line 431). It opens when the reviewer clicks a link (an arrow between two components) on the map. Today it has three blocks:

1. **Header.** The title `<from> → <to>`, the status line (`● added` / `removed` / `changed: the set of referenced symbols changed`), and the lines "Now references: …" (`edge.symbolsAdded`) and "No longer references: …" (`edge.symbolsRemoved`).
2. **FINDINGS.** Every finding anchored to this link (`findingsForEdge` in `app/src/findings.ts`), rendered by `FindingItem` in `app/src/FindingsSection.tsx` as: severity chip, kind label, message, evidence lines, suggestion, and a link for each anchor. `hideAnchor` hides only the anchor that is this link itself.
3. **REFERENCES N.** The link's references grouped by symbol, each with `file:line`. Added symbols are green, removed ones red.

### Observed

The user reported this on 2026-11-17 from a review of this repository, where `helper` (the Swift helper under `helper/`) gained a link to the external package `swift-syntax`. The panel reads:

```
helper → swift-syntax
● added
Now references: import SwiftSyntax

FINDINGS 1
LOW  new dependency
helper now depends on swift-syntax.
helper → swift-syntax (import SwiftSyntax at helper/Sources/reviewmap-swift-helper/SwiftExtractor.swift:3)
swift-syntax

REFERENCES 1
import SwiftSyntax
  helper/Sources/reviewmap-swift-helper/SwiftExtractor.swift:3
```

The panel shows three facts: the link is new, it is flagged LOW as a new dependency, and it has one reference, at `SwiftExtractor.swift:3`. Each fact appears two or three times:

- **"Now references":** on an added link every symbol is new, so this line repeats the REFERENCES list, where the added symbols are already green.
- **The finding's message** ("helper now depends on swift-syntax.") restates the title. The `new-external` check (`new_externals` in `crates/core/src/analyze/checks.rs`, around line 461) writes one finding per package, describing the package. On the panel for one of the links into that package, the description says nothing new.
- **The finding's evidence line** `helper → swift-syntax (import … :3)` is this link's reference again. The check writes one such line per component that newly uses the package.
- **The `swift-syntax` link under the finding:** the check anchors the finding to each new link into the package and to the package component (`Anchor::component(&id)`). The panel hides only the link anchor, so the package anchor shows as a link to the name already in the title.

The same thing happens with `layering` findings (around line 420 in `checks.rs`). Their anchors include both end components (both already in the title), and up to three of their evidence lines are references (`<symbol> at <file>:<line>`, or `<symbol> in <file>` for BUILD-file references) that REFERENCES already lists.

Repro: run `reviewmap` on a change where one component starts depending on an external package that nothing used before. Open the review, click that link on the map, and read the right panel.

### Expected

Each fact once. For the example above:

```
helper → swift-syntax
● added · 1 reference · LOW new dependency

REFERENCES 1
import SwiftSyntax
  helper/Sources/reviewmap-swift-helper/SwiftExtractor.swift:3
```

When a finding does say more than the link, that part stays, on one line per finding. For example, an external package that is also new in the lockfile and that other components also start using:

```
Core → swift-syntax
● added · 3 references
MEDIUM  new dependency   New in the lockfile at 600.0.1 · also new in CLI, helper

REFERENCES 3
…
```

### Changes

All in the UI. The core's findings, their messages and the report format stay as they are.

1. **Status line.**
   - For an `added` or `removed` link, show `● added · N reference(s)` (or `removed`). Drop "Now references" / "No longer references": every reference on such a link is added or removed, and REFERENCES already colors them.
   - For a `changed` link, keep the "Now references" and "No longer references" lines: there they show what changed.
   - N is the link's total reference count (`edge.refCount ?? edge.refs.length`), the same number as the REFERENCES heading.
2. **Findings in context.** On the edge panel, each finding shows only what the panel doesn't already show:
   - **Anchors:** hide the link itself (as today) and also the components at either end of it.
   - **`new-external`:**
     - Don't show the message or the evidence lines.
     - Build the context from report data instead of parsing evidence strings:
       - "New in the lockfile at <version>" when `report.externalDeps` has an entry with `change === "added"` whose `"ext:" + name` equals the link's `to` (the version is that entry's `to`, and is omitted when there is none).
       - "also new in A, B" with the names of the other components that have an `added` link to the same package. Use the same component-name lookup the panel's title uses, and show at most 3 names plus "and N more".
     - When there is no context, the finding becomes just its chip (severity + kind label) at the end of the status line, as in the first example.
   - **`layering`:** keep the message, the first evidence line (which layers the two components are in) and the suggestion. Drop the evidence lines that are references, because REFERENCES lists them. Match these by the `file:line` / `file` of the link's refs, not by the wording of the text.
   - **`cycle`, and any other kind or LLM finding:** unchanged, apart from the anchor rule. A cycle's evidence names each step of the cycle, and most of those steps are not this link.
3. **Elsewhere.** The component panels, the bundle panel (`BundlePanel`) and the Overview's Structural review keep showing findings in full, as they do today: there the text is not repeated.

## Why

The edge panel is the one a reviewer opens most often to answer "what does this new link mean?". Today a single new external dependency takes about 12 lines to say three things, and the reviewer has to read all of them to see that nothing else is there. Links into new external packages are very common, so this costs time on nearly every review. It also teaches reviewers to skim findings, which is risky when a finding really does carry something new.

## Where

- `app/src/Sidebar.tsx`: `EdgePanel` (status line, the "Now references" / "No longer references" lines, findings, REFERENCES).
- `app/src/FindingsSection.tsx`: `FindingItem` / `FindingList` / `FindingsSection`. They need a way to render a finding in the edge context, for example a prop `context?: { edge: Edge }`, or a separate `EdgeFindings` component that the edge panel uses.
- `app/src/findings.ts`: a pure, unit-tested helper that computes what is left of a finding on an edge panel. For example:

  ```ts
  type EdgeFindingView =
    | { kind: "chip"; finding: Finding }                         // only the chip on the status line
    | { kind: "line"; finding: Finding; context: string }        // chip + one line of context (new-external)
    | { kind: "full"; finding: Finding; evidence: string[]; anchors: Anchor[] }; // the remaining evidence and anchors
  function edgeFindingView(index: Index, edge: Edge, f: Finding): EdgeFindingView
  ```

- Data used, read-only:
  - `Finding` (`kind`, `severity`, `message`, `evidence: string[]`, `anchors: Anchor[]`, `source`)
  - `Edge` (`from`, `to`, `status`, `symbolsAdded`, `symbolsRemoved`, `refs`, `refCount`)
  - `ChangeReport.externalDeps: ExternalDepChange[]` (`name`, `change`, `from?`, `to?`), all in `app/src/types.ts`
- `app/src/styles.css`: the chip on the status line and the one-line finding.
- Tests: a Vitest file next to `findings.ts` (or extend the existing findings tests).

## Acceptance criteria

- [ ] An `added` link into a package with a `new-external` finding, no lockfile entry and no other new users (the `helper → swift-syntax` case) shows: the title, `● added · 1 reference · LOW new dependency`, and REFERENCES. There is no "Now references" line, no FINDINGS section and no anchor link.
- [ ] The same finding with a lockfile entry (`externalDeps` `added`, `to: "600.0.1"`) and two other components with `added` links to the package shows one finding line: `MEDIUM new dependency  New in the lockfile at 600.0.1 · also new in <A>, <B>`.
- [ ] A `changed` link still shows "Now references" and "No longer references" with its added and removed symbols.
- [ ] A `layering` finding on the edge panel shows its message, its layer line and its suggestion. It doesn't show evidence lines for references listed under REFERENCES, or anchor links to the link or its two ends.
- [ ] A `cycle` finding on the edge panel looks as it does today, apart from having no anchor links to this link or its two ends.
- [ ] The same findings on a component panel, the bundle panel and the Overview look exactly as they do today.
- [ ] Clicking the chip, or a one-line finding, still goes where the finding leads today (`findingFocus`).
- [ ] Vitest covers `edgeFindingView` for: `new-external` with no context, with a lockfile entry, with other users (including more than 3), `layering` (reference lines dropped, layer line kept) and `cycle`. `bazel test //app:test` and `bazel test //...` pass.
- [ ] Checked by eye in the dev preview (`REVIEWMAP_REPORT=<report> bazel run //app:dev`) on a report with a `helper → swift-syntax`-like link. To get one, run `reviewmap . --base 0cd5916 --head 0e57fa4 --report <file>` in this repository.

## Dependencies and constraints

- No change to the core, the report format or the findings' text. Rules CORE-005 (every finding points at something on the map) and CORE-003 (no name-matched links in the main report) in `statute/rules/core.md` cover how the core makes findings. This task only changes how one panel shows them.
- No finding may disappear from the edge panel: each one is at least a chip with its severity and kind. Severity is still visible without opening anything.
- Don't match evidence by its wording. Use report data (refs, `externalDeps`, links) to decide what to drop or show.
- Related: rm-8byb (group changed external packages into one map node) changes how external packages are drawn on the map. It doesn't change the edge panel, but if it lands first, check that the edge panel still opens for links into the grouped node.
- Related: rm-xn0c (show where an external package is declared and who uses it) improves the external package's own panel, where the full `new-external` finding stays. The two don't touch the same panel.
- Run `statute show` on the files you touch before changing them, and the `statute:change` skill after.
