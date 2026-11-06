---
# rm-ivt2
title: Run Go on a real repo and record progress
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T01:30:00Z
parent: rm-a4b7
---

## Implementation scope
Run the analyzer on the last 40 commits of a mid-size open-source Go repo with several packages and an interface-heavy design, in name matching and in index mode, and look at the map and the structural review findings for false links and noisy findings. Fix what is wrong or file beans for it.

Record timings, what each mode finds, and the decisions made during the step in a "Step 5 notes" section of docs/progress.md, and mark step 5 done. Update README.md: Go moves from planned to supported, and its index mode requirements are listed.

## Acceptance criteria
- [x] The run completes in both modes, and its results are described in docs/progress.md.
- [x] README.md lists Go as supported.
