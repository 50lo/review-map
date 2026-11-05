---
# rm-ltol
title: Run Kotlin on a real repo and record progress
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-aks4
---

## Implementation scope
Run the analyzer in name matching mode on the last 40 commits of a mid-size open-source Android app with several Gradle modules and Compose UI. Look at ambiguity warnings and false links in particular, since there is no index; fix what is wrong or file beans.

Record timings, results, and decisions in a "Step 7 notes" section of docs/progress.md, mark step 7 done, and list Kotlin as supported (name matching only) in README.md.

## Acceptance criteria
- [ ] The run completes, and its results, including the share of ambiguous references, are described in docs/progress.md.
- [ ] README.md lists Kotlin as supported.
