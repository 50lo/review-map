---
# rm-pczu
title: Validate Kotlin indexing on synthetic Gradle and Bazel repos
status: todo
type: task
created_at: 2026-11-07T22:46:17Z
updated_at: 2026-11-07T22:46:17Z
parent: rm-lnrl
blocked_by:
    - rm-mje8
    - rm-bcg9
---

Check Kotlin index mode end to end on throwaway synthetic projects for both builders, record timings, document it, and clean up. Part of the Kotlin index mode epic (rm-lnrl): read its Decisions first. In short: synthetic only, no real repos, no Android, and temporary repos are deleted at the end.

## Implementation scope

1. Create two temporary synthetic git repos in a scratch directory, not in this repo:
   - A Gradle repo: three or four JVM modules, `kotlin("jvm")`, a version catalog, and a test source set.
   - A Bazel repo: rules_kotlin with several packages and a `kt_jvm_test`.
   - Each repo gets a base commit and a head commit. The changes cover a renamed function, a new interface implementation, a same-named class in two packages, and a change used only from tests.
   - Include a symbol-collision check in the Gradle repo: two app modules that each define `fun main()` and `fun start()` in the same package, plus a `src/test` source set. scip-java gives a leaf module's own symbols no Maven coordinates (`scip-java maven . . demo/start().`). Since PR #33, `KotlinIndex.scopeUnqualifiedSymbols` scopes those symbols to the Gradle project (the nearest directory with a build file) before `SCIP.sideIndex` joins definitions. Check end to end that each module's calls stay within that module and that test sources still reach their module's main code.
2. Run `reviewmap analyze --index --no-llm --no-review` on each, both cold and cached. Also run `--no-index` for comparison.
3. Record in `docs/progress.md`:
   - Time per side, cold and cached.
   - Components, edges, findings, and ambiguity warnings with and without index mode.
   - Files without index data.
   - Tool versions: JDK, Gradle, Bazel, scip-java.
   - Disk used by the tools and caches.
4. Update the docs:
   - `README.md`: the Kotlin section currently says name matching only. Add what index mode needs (JDK 17+, Gradle or Bazel, scip-java downloaded on first use), that it runs the repo's build scripts, and that Android isn't supported.
   - `docs/plan.md`: in the language table, the Kotlin index column says "scip-java with the Kotlin compiler plugin". The Kotlin section says index mode is deferred.
   - `docs/progress.md`: the Kotlin notes say rm-0ggn is deferred.
5. Delete the synthetic repos, their reports, `build/` directories, and Bazel output bases. Keep the checked-in test fixtures from the other two tasks. List anything kept outside the repo, such as the scip-java launcher in the index cache or `~/.gradle`, with its size.

## Acceptance criteria

- [ ] Both builders produce exact Kotlin references on the synthetic repos. Any reference index mode misses that name matching found is explained in `docs/progress.md`.
- [ ] Timings and counts are in `docs/progress.md`.
- [ ] `README.md` and `docs/plan.md` describe Kotlin index mode as built.
- [ ] The synthetic repos and their build outputs are removed. What remains is listed.

## Constraints

- Depends on rm-mje8 and rm-bcg9.
- No Android SDK, and no CI changes.
