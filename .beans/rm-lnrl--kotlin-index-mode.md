---
# rm-lnrl
title: Kotlin index mode
status: todo
type: epic
created_at: 2026-11-07T22:46:17Z
updated_at: 2026-11-07T22:46:17Z
---

Give Kotlin an index mode like Go, Rust, TypeScript, and Swift already have, so `reviewmap analyze` with index mode on (`--index` or `index.enabled: true` in reviewmap.yml) gets exact Kotlin references from scip-java instead of name matching. It covers both Gradle and Bazel (rules_kotlin) builds. Today `KotlinLanguage.index` in `Sources/ReviewMapCore/Kotlin/KotlinLanguage.swift` returns nil, so same-named declarations in different packages produce `ambiguous-name` warnings, and the `unused-api`, `orphaned`, and `untested` checks rely on identifier occurrences.

## Decisions (user, 2026-11-08)

- Index mode is wanted however slow it turns out to be. It is not gated on measurements; rm-0ggn is scrapped. Timings are still recorded, as for the other languages.
- Gradle and Bazel are both in scope. Android is not. Nothing in this epic may need the Android SDK. Android modules are not tested, and where they fail to build, Kotlin falls back to name matching.
- Testing uses synthetic projects only, with no real repos cloned. The small checked-in fixtures used by the automated tests stay, as `go-indexed` does for Go. Larger synthetic repos built for end-to-end validation are temporary and removed when the epic is done.
- CI stays minimal. `.github/workflows/ci.yml` installs no Java, Gradle, Bazel, or scip-java and downloads no tools. Tests that need them throw `XCTSkip` when they are missing, and the full suite runs locally.

## Upstream facts (checked 2026-11-08)

- sourcegraph/scip-kotlin is archived and merged into scip-code/scip-java. scip-java v0.14.0 (2026-11-04) rewrote Kotlin indexing on the Kotlin Analysis API: `KotlinAnalysisIndexer` takes a source root, Kotlin sources, and a compile classpath, and writes per-file SCIP shards. `scip-java aggregate` merges the shards into one `index.scip`. The current release is v0.14.1. The rewrite is labelled potentially breaking, and the docs call Kotlin less mature than Java.
- **Gradle** is supported directly. `scip-java index` runs `clean scipPrintDependencies scipCompileAll` with an init script, dumps each Kotlin compile task's sources and classpath, and indexes them. That makes it a full compile on each side.
- **Bazel** is not supported for Kotlin. scip-java's Bazel aspect (`scip_java.bzl`) handles only `Javac` actions. Review Map has to collect sources and classpath for the Kotlin targets itself, then run the Kotlin indexer and aggregate. See rm-bcg9.
- Tools: JDK 17+ (the macOS `/usr/bin/java` stub does not count), Gradle 8+ or the repo's `gradlew`, Bazel or bazelisk, and the scip-java launcher (an 85 MB file from the GitHub release, which needs a JDK). The Mac mini currently has Bazel and bazelisk but no JDK or Gradle.

## Order

1. rm-mje8: shared KotlinIndex plus Gradle.
2. rm-bcg9: builds on the KotlinIndex from rm-mje8.
3. rm-pczu: synthetic repos, timings, docs, and cleanup.
