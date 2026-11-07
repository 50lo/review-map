---
# rm-m7n1
title: Preserve Kotlin caller context when Swift indexing is enabled
status: completed
type: bug
priority: high
created_at: 2026-11-07T11:53:57Z
updated_at: 2026-11-07T12:05:30Z
---

## Problem

Enabling Swift indexing in a mixed Swift/Kotlin monorepo removes Kotlin caller context, even though Kotlin must continue using name matching. All ten changed declarations remain correct, and the indexed report emits no warning about the lost context.

## Reproduction

Observed with Review Map 0.1.0 built from main b51a9ef, Bazel 9.3.1, rules_swift 3.6.1, and full Xcode on macOS.

The synthetic Git monorepo has root MODULE.bazel and BUILD.bazel, ios/Greeting.swift and ios/Screen.swift, and android/Greeting.kt and android/Screen.kt. BUILD.bazel defines a Swift library //:ios_app (module MobileApp, srcs ios/**/*.swift) and a Kotlin library //:android_app. Both base and head contain these build definitions. The feature changes each platform's greeting signature and body, displayName body, caller renderGreeting, removes legacyLabel, and adds normalizedName; stableLabel is unchanged. There are five expected declaration changes per platform.

Local fixture: /private/tmp/reviewmap-mobile-monorepo-ngl0vlne/repo, branch feature/indexed-personalized-greetings. Base main: e5650c171d75eb3c8295b5b72e5295114d5891fc; head: b3eb6fdd2bd049c56b92f646263a81af66ce88b0. Temporary artifacts may be cleaned; the setup and observed behavior below should be preserved in a regression test.

Each platform has greeting and renderGreeting in separate files in the same component. The Kotlin files share package com.example.mobile. On base, greeting(name: String) returns a greeting and renderGreeting calls greeting("Taylor"). On head, greeting takes an additional prefix: String parameter, and renderGreeting calls greeting("Taylor", "Welcome"). The Swift side makes the equivalent change.

Compare a --no-index --no-llm report with an --index --no-llm report from the same commits. For the indexed run, use this config to avoid the separate Bazel path and cache defects:

```yaml
index:
  builder: bazel
  targets: ["//:ios_app"]
  bazelArgs: ["--features=-swift.file_prefix_map", "--disk_cache="]
```

Use an index cache outside the fixture and write each report to a distinct file.

Expected: both reports include android/Screen.kt as a caller context region for folder:android::greeting(), while the indexed report resolves Swift callers from the compiler index.

Actual: name-based output has both platform callers; indexed output retains only the Swift caller. Reproduced from the root, ios/ using cached indexes, and android/ using fresh indexes. Each indexed run passes 21/22 validation checks and fails the Kotlin caller-context check.

## Cause and evidence

Sources/ReviewMapCore/Regions.swift, callers(of:hd:supports:), selects indexed caller lookup with `!b.index.isEmpty` and allows same-component name lookup only with `b.index.isEmpty`. Once any language has an index, those global conditions suppress fallback for declarations in unindexed languages. Lookup should respect the relevant language/file coverage, including partially indexed cases.

Local evidence under /private/tmp/reviewmap-mobile-monorepo-ngl0vlne: change-report-bazel-names.json, change-report-absolute-root.json, change-report-absolute-ios.json, change-report-fresh-android.json, validation-indexed.json, and verify-indexed.py.

## Acceptance criteria

- [x] Kotlin caller context is preserved when Swift indexing is active.
- [x] Indexed Swift caller lookup remains exact and does not regain false-positive name matches.
- [x] Add a mixed-language regression covering indexed and unindexed files in one report, including same-component callers.
- [x] Verify appropriate fallback for uncovered files in a partially indexed language.

## Summary of Changes

- Caller context now combines exact indexed references with name-based references only from caller files missing head index coverage. An index for Swift no longer suppresses Kotlin callers, and a partial Swift index retains callers from uncovered files in the same or other components.
- Covered files, including files with an empty reference list, retain exact lookup. Coverage of the declaration's own file does not decide whether caller files need fallback.
- Added dedicated CallerContextTests with mixed Swift/Kotlin callers, partial Swift coverage with an indexed same-name decoy, covered and uncovered target files, and differing base/head coverage. All three regressions failed before the implementation change and pass afterward.
- Verified 39 tests with `swift test --scratch-path /private/tmp/reviewmap-kotlin-context-build --filter 'CallerContextTests|^ReviewMapCoreTests.IndexTests|ChecksTests|FixtureTests|KotlinTests'`: 0 failures. This includes existing compiler-backed Swift exact-caller checks and the unchanged basic snapshot.
- Statute change review: no affected rules or terms; check reports 0 errors and 0 warnings.

## Validation boundary and existing behavior

The regression tests inject index data; existing IndexTests also exercise a real Swift compiler index. The coordinator will independently validate the combined changes against the shared Bazel synthetic monorepo. This session did not modify or rerun that fixture.

Name-based caller fallback already consumes base-only `usedBy` entries and interprets their lines in the head file; the basic snapshot contains resulting stale caller context. This separate behavior is preserved here. Filtering those entries would change no-index output and is outside rm-m7n1's coverage fix.
