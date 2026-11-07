---
# rm-tjwt
title: Prevent crashes when reading Bazel indexes with relative source paths
status: completed
type: bug
priority: high
created_at: 2026-11-07T11:53:57Z
updated_at: 2026-11-07T12:05:23Z
---

## Problem

A real Bazel Swift build succeeds, but Review Map aborts while reading the index when rules_swift uses its default source-path remapping. The process exits 134 and produces no report.

## Reproduction

Observed with Review Map 0.1.0 built from main b51a9ef, Bazel 9.3.1, rules_swift 3.6.1, and full Xcode on macOS.

The synthetic Git monorepo has root MODULE.bazel and BUILD.bazel, ios/Greeting.swift and ios/Screen.swift, and android/Greeting.kt and android/Screen.kt. BUILD.bazel defines a Swift library //:ios_app (module MobileApp, srcs ios/**/*.swift) and a Kotlin library //:android_app. Both base and head contain these build definitions. The feature changes each platform's greeting signature and body, displayName body, caller renderGreeting, removes legacyLabel, and adds normalizedName; stableLabel is unchanged. There are five expected declaration changes per platform.

Local fixture: /private/tmp/reviewmap-mobile-monorepo-ngl0vlne/repo, branch feature/indexed-personalized-greetings. Base main: e5650c171d75eb3c8295b5b72e5295114d5891fc; head: b3eb6fdd2bd049c56b92f646263a81af66ce88b0. Temporary artifacts may be cleaned; the setup and observed behavior below should be preserved in a regression test.

Configure reviewmap.yml:

```yaml
index:
  builder: bazel
  targets: ["//:ios_app"]
```

From the fixture root, run:

```sh
reviewmap analyze . --index --no-llm --index-cache /tmp/rm-relative-index-cache --summary -o /tmp/rm-relative-report.json
```

Use a fresh index cache. The Swift target compiles successfully, then the reader asserts:

```text
Assertion failed: (!WorkingDir.empty() && "passed relative path without working-dir"), function getCanonicalPath, file Path.cpp, line 53.
```

## Evidence and likely cause

The crash stack goes through IndexBuilder.read -> IndexStoreDB.symbolOccurrences(inFilePath:) -> foreachSymbolOccurrenceInFilePath -> CanonicalPathCacheImpl::getCanonicalPath. In Sources/ReviewMapCore/Swift/SwiftIndex.swift, storedPaths supplies relative candidates after absolute candidates; this query API requires an absolute path. Inspect path remapping as well as the unsafe fallback: avoiding the assertion alone must not silently discard the index.

Adding `bazelArgs: ["--features=-swift.file_prefix_map"]` allows this fixture to index. This is a workaround, not the expected default behavior.

Local evidence: analyze-bazel-root.log and bazel-index-cache/repo/b3eb6fdd2bd049c56b92f646263a81af66ce88b0/build.log under /private/tmp/reviewmap-mobile-monorepo-ngl0vlne. Existing IndexBazelTests use a fake Bazel backed by SwiftPM and did not reproduce this real Bazel output.

## Acceptance criteria

- [x] Default rules_swift path remapping can be read without aborting.
- [x] Both commits retain correct indexed Swift references and caller context; name fallback alone is not a successful fix.
- [x] Cover real Bazel relative-path output and missing/uncovered source files without passing relative paths to an absolute-path-only API.
- [x] Verify root and subdirectory invocation in the Swift/Kotlin monorepo.

## Summary of Changes

- Read the actual rules_swift 3.6.1 unit with libIndexStore: working directory is `.` and the main file is `./ios/Screen.swift`. IndexStoreDB imports these without the Bazel execution root, then the relative query fallback asserts.
- Remap `.` to the persisted execution root during import and query only absolute paths. Use a new database name so previously imported relative keys are rebuilt without recompiling cached stores.
- Add a compiler-backed regression with the same file-prefix mapping, deleted build tree, root/nested workspace mappings, and an uncovered Swift file.
- Real default Bazel cold build and cached reads from root, ios/, and android/ retain index resolution, Swift greeting caller context, all ten declarations, and zero warnings. Evidence: `/private/tmp/reviewmap-indexing-real-{root,ios,android}.{json,log}`. The separate Kotlin caller-context defect remains assigned elsewhere.
- The original synthetic fixture and its existing artifacts were not modified.
