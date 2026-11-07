---
# rm-s3g6
title: Keep Bazel indexes available after disk-cache rebuilds
status: completed
type: bug
priority: high
created_at: 2026-11-07T11:53:57Z
updated_at: 2026-11-07T20:02:46Z
---

## Problem

A Bazel rebuild served from its disk cache succeeds but leaves Review Map with no usable index store. Review Map then emits index-unavailable and falls back to name matching, even though indexing was explicitly requested and the build succeeded.

## Reproduction

Observed with Review Map 0.1.0 built from main b51a9ef, Bazel 9.3.1, rules_swift 3.6.1, and full Xcode on macOS.

The synthetic Git monorepo has root MODULE.bazel and BUILD.bazel, ios/Greeting.swift and ios/Screen.swift, and android/Greeting.kt and android/Screen.kt. BUILD.bazel defines a Swift library //:ios_app (module MobileApp, srcs ios/**/*.swift) and a Kotlin library //:android_app. Both base and head contain these build definitions. The feature changes each platform's greeting signature and body, displayName body, caller renderGreeting, removes legacyLabel, and adds normalizedName; stableLabel is unchanged. There are five expected declaration changes per platform.

Local fixture: /private/tmp/reviewmap-mobile-monorepo-ngl0vlne/repo, branch feature/indexed-personalized-greetings. Base main: e5650c171d75eb3c8295b5b72e5295114d5891fc; head: b3eb6fdd2bd049c56b92f646263a81af66ce88b0. Temporary artifacts may be cleaned; the setup and observed behavior below should be preserved in a regression test.

Use this configuration to isolate the cache issue from the separate relative-path crash:

```yaml
index:
  builder: bazel
  targets: ["//:ios_app"]
  bazelArgs: ["--features=-swift.file_prefix_map"]
```

1. From the monorepo root, run reviewmap analyze . --index --no-llm with this config, an explicit --index-cache outside the repo, and an output report path. Start with a fresh cache. Both commit indexes build successfully, warming Review Map's .bazel-disk-cache.
2. From android/, run the same comparison with the same config and cache, adding --rebuild-index and writing a separate report.
3. Repeat from android/ with `--disk_cache=` added to bazelArgs to force compiler execution.

Actual in step 2: Bazel reports a successful build with 25 disk cache hits and 23 internal processes. Review Map logs `The head build produced no index store (bazel build //:ios_app)` and writes a name-based report with one index-unavailable warning. Step 3 builds both commits and produces an indexed report with no warnings.

## Investigation and evidence

Sources/ReviewMapCore/Swift/SwiftIndex.swift builds with swift.index_while_building and swift.use_global_index_store, locates the global store, and otherwise merges per-target .indexstore directories. Investigate how index artifacts/global-store side effects are restored on action-cache hits and whether the fallback locates the output format produced by rules_swift. The precise missing-output/import cause is not yet established.

Disabling the disk cache is an experiment workaround. Keeping it disabled globally should not be the assumed fix.

Local evidence under /private/tmp/reviewmap-mobile-monorepo-ngl0vlne: analyze-absolute-android.log, bazel-disk-cache-no-index.log, analyze-fresh-android.log, and change-report-fresh-android.json. The failed rebuild preserved previously cached stores, but the current run still fell back to names.

## Acceptance criteria

- [x] A warm Bazel disk-cache rebuild yields usable indexes for both commits, or performs a targeted rebuild when required index artifacts are unavailable.
- [x] Preserve exact references and indexed resolution across cold builds, cached-store reuse, and --rebuild-index with disk-cache hits.
- [x] Preserve previously valid cached stores when a rebuild fails.
- [x] Add a regression exercising real or faithfully reproduced Bazel cache outputs, including invocation from a platform subdirectory.

- [x] Mixed cache-hit/compiler-execution builds retain indexed references from every compiled module.

## Summary of Changes

- Reproduced the real cached build with 25 disk-cache hits: the global store was absent and `ios_app.indexstore` existed without materialized units/records. The existing merge logic recognized the layout correctly; no usable files had been downloaded.
- Confirmed rules_swift 3.6.1 exports the declared artifacts in `swift_index_store`. Bazel 9.3.1 defaults to downloading top-level outputs, so requesting `--output_groups=+swift_index_store` restores that store. Added `--remote_download_regex=.*[.]indexstore(/.*)?` to restore transitive library stores too. Global indexing, file-prefix mapping, and the disk cache remain enabled.
- A separate real two-module fixture restored both application and dependency units/records on a warm build with 26 disk-cache hits. Evidence: `/private/tmp/reviewmap-indexing-transitive-{cold,warm}.log` and corresponding output bases.
- Reworked the fake Bazel integration fixture to compile real remapped units per module and model selective cached-output materialization. Regression coverage compares exact references for both commits, review items, and regions across cold builds, cached-store reuse, forced disk-cache rebuilds, failed builds, and successful builds with missing index artifacts. Cleanup assertions now inspect only the test's own output bases.
- Validation: 14 Swift index regression tests passed. The real synthetic monorepo cold root build, ios/ cache reuse, and android/ and root forced rebuilds preserve index resolution, all ten declaration changes, Swift caller context, and zero warnings. Both commits in each forced rebuild recorded 25 disk-cache hits. Reports and build logs are in `/private/tmp/reviewmap-indexing-final-evidence/`.
- The original synthetic fixture and its existing caches/artifacts remain unchanged. The separately assigned Kotlin caller-context fix is not part of this commit.

### Mixed-cache review follow-up

- Reproduced the partial-global-store case with a warm two-module Bazel fixture, an app-only source edit, and a fresh output base. The build recorded 24 disk-cache hits and one Swift compiler execution; its global store contained only `Screen.swift`, while the downloaded dependency store contained `Greeting.swift`. The previous global-first return ignored the dependency.
- Merge declared stores and the global store together, retaining support for global-only output. The PR review follow-up below changes this to merge into the existing global store and retain its already present records.
- The integration fixture now caches modules independently and populates its global store only for compiler executions. It verifies all compiled files on both sides, explicitly forces mixed app/dependency cache results, compares exact references and caller/definition regions, and checks global-only output and retained caches after failures. The new coverage failed against the old selector, then all 14 index tests passed after the fix.
- Real analyzer verification: the new app commit had 24 disk-cache hits plus one Swift compiler execution, and the base had 26 disk-cache hits. Both saved stores contain both source units, resolution remains `index`, and the app receives definition context for the cached dependency's `greeting(name:prefix:)`. No index warnings occurred. The fixture still has its unrelated `unresolved-import` warning because module `Greetings` is not represented by a discovered component. Evidence: `/private/tmp/reviewmap-indexing-mixed-validation.json`, `/private/tmp/reviewmap-indexing-mixed-analysis.json`, and `/private/tmp/reviewmap-indexing-mixed-after.log`.

### PR #28 merge and test-scope review

- Merge declared output stores into the existing global store when available; otherwise merge into scratch and retain the global-only fallback. Removed the `including` parameter and the full global-store copy. A focused filesystem test verifies existing content and inode identity survive the merge, a repeated merge copies nothing, and missing-global/global-only cases remain supported.
- Replaced the fake disk-cache state machine with one fixed mixed-output layout: Feed is in the global store and dependency indexes are available only in per-target stores. Retained full file coverage and exact reference checks for both commits, output-group/download flag assertions, exact caller checks, and one failed-rebuild preservation case. Reduced each flow to three analyzer runs. Actual cache hits continue to be verified with real Bazel rather than simulated state.
- All 16 index tests pass (`/private/tmp/reviewmap-indexing-review-tests-final.log`). The unchanged original monorepo passed cold-root, ios/ reuse, and android/ forced disk-cache rebuild checks with all ten declarations, both platform caller contexts, and no warnings. Reports/build logs are under `/private/tmp/reviewmap-indexing-review-evidence/`; all runs used new private cache paths.
- The separate two-module fixture was used read-only. Its mixed base build recorded 24 disk-cache hits and one Swift compiler execution; both sides retain both source units and indexed dependency definition context. No index warnings; the existing unrelated `Greetings` component-discovery warning remains. See `mixed-validation.json` in the evidence directory.
