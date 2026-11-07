---
# rm-ltol
title: Validate Kotlin on a small synthetic project and record progress
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-07T01:13:40Z
parent: rm-aks4
---

## Implementation scope
Run the analyzer in name matching mode on a small synthetic multi-module Gradle fixture pair with Compose UI and Android contracts. Cover imports across packages and modules, test source sets, intentional ambiguous references, and false-link avoidance; fix incorrect results or file beans. This replaces the real-project run at the user’s explicit request on 2026-11-07 to limit disk use. No real repository clone, Android build, or Gradle execution is required. Reuse local tools, keep CI minimal, monitor free disk space, and remove temporary validation artifacts afterward.

Record timings, results, and decisions in a "Step 7 notes" section of docs/progress.md, mark step 7 done, and list Kotlin as supported (name matching only) in README.md.

## Acceptance criteria
- [x] The run completes, and its results, including the share of ambiguous references, are described in docs/progress.md.
- [x] README.md lists Kotlin as supported.

## Summary of Changes

Extended the small Kotlin fixture with Compose, Android manifest permissions, a test source set, and one deliberate wildcard-import ambiguity. The actual CLI report completed in 1.87 s with 6 components, 5 edges, 11 review items, and 20 regions. Six of seven internal cross-component name-reference sites at head resolve; the deliberately ambiguous seventh is reported without a false link (14.3%, a synthetic stress case only). README and Step 7 progress notes document support, limits, and validation.

Final checks: 140 Swift tests pass excluding the pre-existing Annotator subprocess stall; six Annotator tests passed before the stall was confirmed by process/stack inspection. The exact CI smoke filter selects and passes two tests. 109 viewer tests, viewer production build, four Chromium layout/theme checks, Statute, Beans, and diff validation pass. No real project, Android build, new Java/Gradle install, or index experiment was used. Temporary test artifacts were cleaned; free disk remained about 63 GiB.
