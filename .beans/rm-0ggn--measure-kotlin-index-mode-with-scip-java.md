---
# rm-0ggn
title: Measure Kotlin index mode with scip-java
status: todo
type: task
priority: low
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-aks4
---

Exact references for Kotlin need a compile: scip-java indexes Kotlin through the semanticdb-kotlinc compiler plugin, run inside a Gradle build. That has Swift's cost problem, so measure before building index mode.

## Implementation scope
On the real repo from rm-ltol, run scip-java's Gradle integration at two commits and record: clean time, time with a warm Gradle cache and build directory, the share of references it resolves, and what it needs installed (JDK, Android SDK). Compare with name matching's ambiguity rate.

Record the numbers in docs/progress.md and propose either index mode (with the warm-cache approach from step 8) or name-matching improvements, as a new bean.

## Acceptance criteria
- [ ] Numbers for both runs are in docs/progress.md, with a recommendation.

## Constraints
No index mode code in this task.
