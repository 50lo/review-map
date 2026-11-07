---
# rm-0ggn
title: Measure Kotlin index mode with scip-java
status: scrapped
type: task
priority: deferred
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-07T22:46:26Z
---

Decide whether Kotlin index mode is worth its cost by measuring what scip-java costs and resolves on Kotlin code. `KotlinLanguage.index` in `Sources/ReviewMapCore/Kotlin/KotlinLanguage.swift` returns nil today, so Kotlin references always come from name matching, and `docs/plan.md` holds index mode back until the numbers exist, as it does for Swift.

## What is known without measuring

Checked against scip-code/scip-java on 2026-11-08. This replaces the earlier assumption that indexing goes through the semanticdb-kotlinc compiler plugin, which is gone: sourcegraph/scip-kotlin is archived and merged into scip-java.

- v0.14.0 (2026-11-04) rewrote Kotlin indexing on the Kotlin Analysis API and calls itself potentially breaking. The current release is v0.14.1. The docs still call Kotlin less mature than Java. There are no older numbers to rely on.
- It is still a build. `scip-java index` runs `clean scipPrintDependencies scipCompileAll` under Gradle, and a finalizer on the Kotlin compile tasks dumps sources and classpath, which scip-java then indexes. Each side of a review is a `git archive` export with no `build/` directory, so each side compiles from scratch: Swift's cost problem, not Go's.
- The analysis no longer depends on the project's Kotlin compiler version, so the old limit of one Kotlin major version per release should not apply.
- A cached compile still counts as executed, so Gradle's build cache may let the base and head sides share unchanged modules. Nothing has tried this.
- Requirements: JDK 17+, Gradle 8+ (the repo's `gradlew`, or `gradle` on the PATH), and the 85 MB launcher from the GitHub release (or coursier). Android modules also need the Android SDK. Maven and Bazel Kotlin are not automatic.
- The Mac mini has none of these today. `/usr/bin/java` is only the macOS stub and fails when run.

## Implementation scope

Run `scip-java index` at two commits and record:

- Clean time per side, and time with a warm `~/.gradle`.
- Time with Gradle's build cache on (`scip-java index -- clean scipPrintDependencies scipCompileAll --build-cache`), base then head.
- The share of Kotlin references resolved, compared with name matching's ambiguity rate on the same commits.
- Whether references across Gradle modules link. `SCIP.sideIndex` in `Sources/ReviewMapCore/SCIP.swift` joins definitions and references by symbol string, so the symbol has to be identical in both modules.
- Whether `Document.relative_path` and `project_root` work when the Gradle root sits below the repo root.
- Disk used: JDK, launcher, Gradle distribution, `~/.gradle`, and per-project `build/`.

Then record the numbers in `docs/progress.md` and recommend one of: start rm-mje8, or scrap it in favour of name-matching improvements with a new bean.

## Open choice for the user

Which code to measure on. This bean originally said a real Kotlin project, but on 2026-11-07 the user replaced real-project work with synthetic work to limit disk use. The options are the new JVM fixture alone, or one small JVM-only real repo as well. Skip Android unless the user asks, since the SDK alone costs several GB. Ask before starting.

## Acceptance criteria

- [ ] Numbers for the runs above are in `docs/progress.md`, with the code measured on named.
- [ ] `docs/progress.md` states a recommendation.
- [ ] Temporary clones, build outputs, and any tools installed only for this are removed afterwards, or listed with their size.

## Constraints

No index mode code in this task. CI stays as it is, with no Java or Gradle added.

Deferred outside the Kotlin implementation by the user's 2026-11-07 scope change. The real-project validation and associated scip-java experiment are not required for the Kotlin support epic. Preserve this task for a future explicit request; its measurements have not been performed.


## Reasons for Scrapping

On 2026-11-08 the user said Kotlin index mode should be built regardless of its speed. They had asked to drop the measurement gate, not the indexing. Measuring first is therefore no longer wanted. Timings are still recorded as part of rm-pczu under the Kotlin index mode epic (rm-lnrl), which replaces this bean.
