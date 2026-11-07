---
# rm-0ggn
title: Measure Kotlin index mode with scip-java
status: todo
type: task
priority: deferred
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-07T00:43:55Z
---

Exact references for Kotlin need a compile: scip-java indexes Kotlin through the semanticdb-kotlinc compiler plugin, run inside a Gradle build. That has Swift's cost problem, so measure before building index mode.

## Implementation scope
On a separately selected real Kotlin project, run scip-java's Gradle integration at two commits and record: clean time, time with a warm Gradle cache and build directory, the share of references it resolves, and what it needs installed (JDK, Android SDK). Compare with name matching's ambiguity rate.

Record the numbers in docs/progress.md and propose either index mode (with the warm-cache approach from step 8) or name-matching improvements, as a new bean.

## Acceptance criteria
- [ ] Numbers for both runs are in docs/progress.md, with a recommendation.

## Constraints
No index mode code in this task.

Deferred outside the Kotlin implementation by the user’s 2026-11-07 scope change. The real-project validation and associated scip-java experiment are not required for the Kotlin support epic. Preserve this task for a future explicit request; its measurements have not been performed.
