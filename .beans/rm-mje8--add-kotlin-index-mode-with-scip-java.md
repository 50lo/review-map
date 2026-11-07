---
# rm-mje8
title: Add Kotlin index mode for Gradle
status: completed
type: task
priority: normal
created_at: 2026-11-07T21:29:19Z
updated_at: 2026-11-07T23:08:29Z
parent: rm-lnrl
---

Add Kotlin index mode for Gradle builds, plus the shared Kotlin index code that rm-bcg9 (Bazel) extends. Part of the Kotlin index mode epic (rm-lnrl): read its Decisions and Upstream facts first. In short: no measurement gate, no Android SDK, CI unchanged, and tests skip without the tools.

## Implementation scope

Add `Sources/ReviewMapCore/Kotlin/KotlinIndex.swift`, modelled on `Sources/ReviewMapCore/Go/GoIndex.swift`:

```swift
enum KotlinIndex {
    /// scip-java release downloaded when none is on the PATH. `REVIEWMAP_SCIP_JAVA` names another command.
    static let scipJavaVersion = "v0.14.1"
    static func load(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]
}
```

`KotlinLanguage.index` in `Sources/ReviewMapCore/Kotlin/KotlinLanguage.swift` returns `try KotlinIndex.load(...)`.

What `load` does for each side:

- A side with no Kotlin files returns `SideIndex(refs: [:])`.
- **Builder choice**:
  - With `options.builder` set to `"bazel"`, use Bazel (rm-bcg9).
  - With `"gradle"`, use Gradle.
  - Otherwise, Gradle roots exist means Gradle, and a Bazel workspace means Bazel. Detect the workspace with `SwiftIndex`'s `bazelWorkspace` helper, moving it somewhere shared if needed.
  - Neither throws `IndexError`.
  - Until rm-bcg9 lands, Bazel throws `IndexError("Kotlin index mode does not support Bazel yet")`.
  - Add `"gradle"` to the `builder` doc comment in `Sources/ReviewMapCore/Index.swift`. Today `"gradle"` makes Swift's index throw "Unknown index builder". Make sure a Kotlin-only builder value doesn't break a mixed Swift and Kotlin repo, for example by having Swift ignore `gradle`.
- **Gradle roots**: the outermost directories of the exported tree with `settings.gradle(.kts)`, or else `build.gradle(.kts)`. One index per root.
- **Cache** at `<cacheDir>/<repo>/<sha>/kotlin/<slug>.scip`, with `.log` and `.notes.txt` beside it. `options.rebuild` forces a build. A cache hit needs no tools.
- **Build**: from the root, run `<scip-java> index --output <path>.tmp`, then move the result into place as GoIndex does.
- **Read**: `SCIP.decode`, then set `projectRoot` to `URL(fileURLWithPath: join(s.dir, root)).absoluteString` (the cached index came from another export), then `SCIP.sideIndex(indexes, sourceRoot: s.dir, known: Set(s.files))`.

Finding scip-java, in order:

1. `REVIEWMAP_SCIP_JAVA`, split on spaces.
2. `scip-java` on the PATH.
3. `<cacheDir>/tools/scip-java-<version>/scip-java`, downloaded with curl from `https://github.com/scip-code/scip-java/releases/download/<version>/scip-java-<version>`, verified against the release's `.sha256` asset, and made executable.

Each of these throws `IndexError`, which makes `Analyzer.swift` emit `index-unavailable` and name-match both sides:

- No working JDK. Check the exit status of `java -version`, because the macOS stub makes `Shell.exists("java")` true without a JDK.
- No executable `gradlew` and no `gradle` on the PATH.
- scip-java exits non-zero or writes no output, for example on compile errors, an Android module without the SDK, or unreachable private repositories.

Kotlin files without index data (`.kts` scripts, non-JVM Multiplatform targets) stay on name matching through the existing per-file handling in `ChangeReportBuilder.addIndex`.

## Tests

- Add `Tests/ReviewMapCoreTests/KotlinIndexTests.swift`, modelled on `GoIndexTests.swift`.
- Add a small fixture pair at `Tests/ReviewMapCoreTests/Fixtures/kotlin-gradle-indexed/{base,head}`: two JVM modules with `kotlin("jvm")`, no third-party dependencies, no Gradle wrapper (so no binary jar is committed), and the same class name in two packages.
- The existing `Fixtures/kotlin` pair can't be built: its app module applies `kotlin("android")` without the Android Gradle plugin.

## Acceptance criteria

- [x] On the fixture, a reference that name matching resolves wrongly (it counts `start()` as a caller of both `Store.load()` and `Cache.load()`) resolves to the right declaration, from one Gradle module into the other. A same-named class in two packages turned out not to be a usable case: name matching already resolves explicit-over-star imports, and a truly ambiguous reference does not compile.
- [x] A second run on the same commits uses the cache and starts no Gradle.
- [x] With `REVIEWMAP_SCIP_JAVA=false`, analysis finishes with name matching and an `index-unavailable` warning. This test needs no tools.
- [x] The tool-dependent tests `XCTSkip` without a JDK, Gradle, or scip-java.
- [x] A Swift and Kotlin repo indexed with the default builder still indexes Swift as before (the default path is unchanged). `IndexTests.testGradleBuilderLeavesSwiftAlone` checks that `--index-builder gradle` no longer breaks Swift; it fails without the fix.
- [x] Without index mode, Kotlin analysis still needs no JDK, Gradle, or Android SDK.
- [x] `swift test` passes locally with the tools installed.

## Constraints

- No Android SDK, and no CI changes (see the epic).
- Index mode runs the repo's Gradle scripts, as Swift's index build does. TypeScript installs with scripts off, so rm-pczu must document this difference.
- Run `statute show` on the touched files first, and the `change` skill afterwards, as `AGENTS.md` requires.

## Summary of Changes

Added `Sources/ReviewMapCore/Kotlin/KotlinIndex.swift`: per side, it finds the outermost Gradle builds, runs `scip-java index` (v0.14.1, from `REVIEWMAP_SCIP_JAVA`, the PATH, or a SHA-256-checked download into `<cache>/tools/`), caches per commit and build under `kotlin/`, and reads the result with the unchanged `SCIP.sideIndex`. A missing JDK (checked by running `java -version`, so the macOS stub doesn't count), missing Gradle, or a failed build throws, which falls back to name matching at both sides. Bazel workspaces and `--index-builder bazel` throw 'not supported yet' until rm-bcg9 lands. Swift ignores `--index-builder gradle`. `KotlinIndexTests` (5 tests) and `Fixtures/kotlin-gradle-indexed` cover exact cross-module resolution, the cache, a failing indexer, a PATH without Java, and Gradle build discovery. The full suite passed locally with OpenJDK 27.0.1 and Gradle 9.8.2, with no skips. The Swift index tests ran with the default builder unchanged. README, plan, and progress were updated.
