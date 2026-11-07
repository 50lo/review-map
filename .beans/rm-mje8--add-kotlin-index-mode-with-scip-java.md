---
# rm-mje8
title: Add Kotlin index mode with scip-java
status: todo
type: task
created_at: 2026-11-07T21:29:19Z
updated_at: 2026-11-07T21:29:19Z
blocked_by:
    - rm-0ggn
---

Add Kotlin index mode, so that `reviewmap analyze` with index mode on gets exact Kotlin references from scip-java. Today `KotlinLanguage.index` returns nil and Kotlin uses name matching only, so same-named declarations in different packages end up as `ambiguous-name` warnings, and the `unused-api`, `orphaned`, and `untested` checks rely on identifier occurrences. Go, Rust, and TypeScript already have index modes built on the shared SCIP reader; this adds Kotlin the same way.

Do not start until rm-0ggn recommends it. That task carries the measured cost and the current facts about scip-java v0.14.

## Implementation scope

Add `Sources/ReviewMapCore/Kotlin/KotlinIndex.swift`, modelled on `Sources/ReviewMapCore/Go/GoIndex.swift`, about 100 to 150 lines:

```swift
enum KotlinIndex {
    /// The scip-java release downloaded when none is on the PATH. `REVIEWMAP_SCIP_JAVA` names another command.
    static let scipJavaVersion = "v0.14.1"
    static func load(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]
}
```

`KotlinLanguage.index` in `Sources/ReviewMapCore/Kotlin/KotlinLanguage.swift` calls it, with the same signature every language has in `Sources/ReviewMapCore/Language.swift`.

For each side in `load`:

- A side with no Kotlin files returns `SideIndex(refs: [:])`.
- Gradle roots are the outermost directories of the exported tree with a `settings.gradle` or `settings.gradle.kts`, or else a `build.gradle` or `build.gradle.kts`. Each root gets one index. No root throws `IndexError`.
- Cache at `<cacheDir>/<repo>/<sha>/kotlin/<slug>.scip`, with the log and `.notes.txt` beside it. `options.rebuild` forces a build. A cache hit needs no Java.
- Build from the Gradle root with `<tool> index --output <path>.tmp`, adding the build-cache arguments only if rm-0ggn shows they help. On success, move the output into place as GoIndex does.
- Decode with `SCIP.decode`, set `index.projectRoot` to `URL(fileURLWithPath: join(s.dir, gradleRoot)).absoluteString` because the cached index came from another export, and combine with `SCIP.sideIndex(indexes, sourceRoot: s.dir, known: Set(s.files))`. SCIP.swift should need no changes, unless rm-0ggn found otherwise.

Finding the tool, in order: `REVIEWMAP_SCIP_JAVA`, split on spaces; `scip-java` on the PATH; `<cacheDir>/tools/scip-java-<version>/scip-java`, downloaded from `https://github.com/scip-code/scip-java/releases/download/<version>/scip-java-<version>`, checked against the release's `.sha256` asset, and marked executable.

Failure handling, in every case by throwing `IndexError`, so `Analyzer.swift` warns `index-unavailable` and name-matches both sides:

- Java is missing. Run `java -version` and check its exit status, because the macOS stub at `/usr/bin/java` makes `Shell.exists("java")` true without a JDK.
- Neither an executable `gradlew` nor `gradle` on the PATH.
- scip-java exits non-zero or writes no output. This covers compile errors, a missing Android SDK, and private dependencies. A broken module costs the whole Kotlin index for that run, which keeps the code simple.

Kotlin Multiplatform non-JVM targets and `.kts` files have no Kotlin compile task to index. They stay on name matching through the file-level handling in `addIndex`, which already exists.

Update `README.md` (the Kotlin section says name matching only), `docs/plan.md` (the table row naming the compiler plugin, and the Kotlin index-mode line), and `docs/progress.md` (Kotlin notes and the timing).

## Tests

Add `Tests/ReviewMapCoreTests/KotlinIndexTests.swift`, modelled on `GoIndexTests.swift`, about 100 to 150 lines, and a new fixture pair at `Tests/ReviewMapCoreTests/Fixtures/kotlin-indexed/{base,head}`: two JVM Gradle modules with `kotlin("jvm")`, no third-party dependencies, and no wrapper, so that no binary jar is committed. The existing `Fixtures/kotlin` pair cannot be used, because its app module applies `kotlin("android")` without the Android Gradle plugin and does not compile.

## Acceptance criteria

- [ ] On the fixture, a reference that name matching leaves ambiguous (the same class name in two packages) resolves to the right declaration, including across the two Gradle modules.
- [ ] A second run with the same commits uses the cache and does not start Gradle.
- [ ] With `REVIEWMAP_SCIP_JAVA=false`, analysis completes with name matching and an `index-unavailable` warning. This test needs no Java.
- [ ] The tests that need tools throw `XCTSkip` when Java, Gradle, or scip-java is missing.
- [ ] `swift test` passes locally with the tools installed, and the skipped path also passes without them.
- [ ] Run with `--no-index`, or without index mode on, a Kotlin repo still needs no Java, Gradle, or Android SDK.
- [ ] `README.md`, `docs/plan.md`, and `docs/progress.md` describe Kotlin index mode and what it needs.

## Dependencies and constraints

- Blocked by rm-0ggn. If that task recommends against index mode, scrap this one.
- CI stays minimal: `.github/workflows/ci.yml` must not install Java, Gradle, or scip-java, and must download no tools. Unlike the Go and Rust tasks, "runs in CI" is not an acceptance criterion. Full tests run locally.
- Do not run Gradle outside index mode. The name-matching path must stay free of a JVM.
- Index mode runs the repository's Gradle scripts, as Swift's build already does, unlike TypeScript, which installs with scripts off. The README must say so. A repo with `index.enabled: true` that contains Kotlin will now also compile it.
- Android is not part of this task's fixture. It works only where the SDK is installed, and otherwise falls back.
- Run `statute show` on the files you touch before changing them, and the `change` skill afterwards, as `AGENTS.md` requires.
