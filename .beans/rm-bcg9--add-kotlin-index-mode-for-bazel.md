---
# rm-bcg9
title: Add Kotlin index mode for Bazel
status: completed
type: task
created_at: 2026-11-07T22:46:17Z
updated_at: 2026-11-07T22:46:17Z
parent: rm-lnrl
blocked_by:
    - rm-mje8
---

Extend Kotlin index mode (KotlinIndex from rm-mje8) to Bazel workspaces that build Kotlin with rules_kotlin (`kt_jvm_library`, `kt_jvm_binary`, `kt_jvm_test`). Part of the Kotlin index mode epic (rm-lnrl): read its Decisions and Upstream facts first. In short: no Android SDK, CI unchanged, and tests skip without the tools.

## Why Review Map has to drive it

`scip-java index` supports Kotlin only under Gradle. Its Bazel aspect (`scip_java.bzl` in scip-code/scip-java) indexes only `Javac` actions. The Kotlin indexer itself is build-agnostic, though: `KotlinAnalysisIndexer` (CLI entry `org.scip_code.scip_java.kotlin_analysis.MainKt`, flags `--sourceroot <dir> --targetroot <dir> --classpath <jars separated by ':'> <sources...>`) writes SCIP shards under `<targetroot>/META-INF/scip/`, and `scip-java aggregate --output <file> <targetroot>` merges them. So Review Map supplies the sources and classpath.

## Implementation scope

In `KotlinIndex`, the Bazel branch for each side (or each workspace):

1. Write a small aspect into the exported tree (a throwaway copy), for example `.reviewmap/kotlin_index.bzl` with an empty `BUILD.bazel`. For each target that has `JavaInfo` and `.kt` sources, it writes a manifest. The manifest lists the source paths relative to the workspace, and the compile classpath: `JavaInfo.transitive_compile_time_jars` plus the Kotlin stdlib from the rules_kotlin toolchain if it isn't already in that list. The manifest and the classpath jars go in an output group, so that building it also builds the jars.
2. Run `bazel build --aspects=//.reviewmap:kotlin_index.bzl%reviewmap_kotlin --output_groups=reviewmap_kotlin <targets>`.
   - Prefer bazelisk, as SwiftIndex does.
   - Targets come from `options.targets`, defaulting to `//...`.
   - Append `options.bazelArgs`.
   - Read the manifests from `bazel-bin`, and resolve jar paths against `bazel info execution_root`.
3. Run the Kotlin indexer once per manifest into one targetroot under the side's cache directory, with `--sourceroot` set to the exported workspace.
   - Prefer the scip-java launcher with the main class above, for example `java -cp <launcher> org.scip_code.scip_java.kotlin_analysis.MainKt`. First confirm that the launcher's embedded jar can be used this way.
   - If it can't, download `org.scip-code:scip-kotlin-analysis:0.14.1` and its runtime dependencies from Maven Central into `<cacheDir>/tools/`, pinned like the launcher.
4. Run `scip-java aggregate --output <workspace-slug>.scip.tmp <targetroot>`, then cache, decode, and combine exactly as the Gradle path does. Cache-hit behaviour is the same: no Bazel run.

Failures throw `IndexError`, giving `index-unavailable` and name matching at both sides:

- No Bazel or bazelisk.
- No JDK 17+.
- The build fails, or no manifests are produced (no rules_kotlin targets).

Bazel's own output base is outside the export, under Bazel's default for the export path, as for Swift's Bazel builds. Delete it afterwards, or reuse SwiftIndex's approach, so that each review doesn't leave a new output base behind.

## Tests

- Extend `KotlinIndexTests.swift` with a small checked-in fixture pair at `Tests/ReviewMapCoreTests/Fixtures/kotlin-bazel-indexed/{base,head}`: a `MODULE.bazel` with pinned `rules_kotlin` and `rules_java`, two `kt_jvm_library` packages with the same class name, and one target using both.
- It `XCTSkip`s without Bazel or a JDK.

## Acceptance criteria

- [x] On the Bazel fixture, the ambiguous reference resolves to the right declaration across Bazel packages.
- [x] A cached second run starts no Bazel.
- [x] Without Bazel installed (simulated through PATH or an env override), analysis completes with name matching and `index-unavailable`.
- [x] A workspace with both Swift and Kotlin targets still indexes Swift as before. Kotlin indexing does not change Swift's Bazel flags or outputs.
- [x] `swift test` passes locally with the tools installed. No leftover Bazel output bases from the tests.

## Constraints

- Depends on rm-mje8 (KotlinIndex, the tool lookup, and the fallback tests).
- No Android (`kt_android_library` is out of scope) and no CI changes.
- Run `statute show` first and the `change` skill afterwards, per `AGENTS.md`.

## Summary of Changes

Added `Sources/ReviewMapCore/Kotlin/KotlinBazel.swift`, which `KotlinIndex.load` calls for `--index-builder bazel` or a Bazel workspace without a Gradle build. It writes an aspect into the export (`.reviewmap_kotlin/kotlin_index.bzl`, removed afterwards) that reads rules_kotlin's `KtJvmInfo` (loaded from `@rules_kotlin//kotlin/internal:defs.bzl`, following a `repo_name` in MODULE.bazel), follows `deps`/`exports`/`associates`/`runtime_deps`, and writes one JSON manifest per target with its main-repo Kotlin sources, its compile classpath without its own jars (the Kotlin stdlib is already in `transitive_compile_time_jars`), and its main-repo dependencies. `bazel build --aspects=... --output_groups=reviewmap_kotlin --lockfile_mode=off` runs on `options.targets` (default `//...`) plus `bazelArgs`, in a temporary output base that is expunged and deleted afterwards, with the shared disk cache. Then `java -cp <launcher> org.scip_code.scip_java.kotlin_analysis.MainKt` (the 85 MB release launcher is a fat jar, so this works) indexes each target, and `java -jar <launcher> aggregate` merges the shards. The index and the targets are cached per commit and workspace as `kotlin/bazel-<name>.scip` and `.targets.json`. rules_kotlin jars carry no Maven coordinates, so every symbol is `scip-java maven . . ...`; only symbols that two targets declare are scoped to their declaring target, so cross-target references still link. Tests: `KotlinBazelIndexTests` (6) with `Fixtures/kotlin-bazel-indexed` (rules_kotlin 2.4.21, rules_java 9.9.0, Bazel 9.3.1, `jvm_target = "21"`), plus `IndexBazelTests.testKotlinLeavesSwiftBazelBuildAlone`. `.bazelignore` keeps the fixture out of this repo's Bazel build. The full suite (179 tests) passed locally with OpenJDK 27.0.1 and Bazel 9.3.1, with no failures. The `change` skill named in AGENTS.md was not available in this session.
