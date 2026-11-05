---
# rm-31f9
title: Add Gradle components and pins
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-aks4
---

## Implementation scope
- Add a `gradleModule` component kind (Model.swift and viewer/src/types.ts).
- Modules from the `include(...)` calls in `settings.gradle.kts` or `settings.gradle`, read as text (both DSLs, `:a:b` paths, `projectDir` overrides where they are a plain string). A repo without settings but with one `build.gradle(.kts)` is one module.
- Source sets: `src/main/kotlin` and `src/main/java` belong to the module; `src/test`, `src/androidTest`, `src/testFixtures`, and Kotlin Multiplatform's `*Test` source sets go to its test component. KMP main source sets (`commonMain`, `jvmMain`, `androidMain`, `iosMain`) stay in the module.
- Module dependencies from `project(":x")` and type-safe `projects.x` accessors in build files become manifest edges.
- Pins from `gradle/libs.versions.toml` (versions and libraries, keyed by `group:name`). `package(ofModule:)` maps a Kotlin package to a pinned library only where the group matches the package prefix; otherwise imports from unknown packages are external by their first two segments.
- Platform modules: `kotlin`, `java`, `javax`, `android`, and `dalvik`. `kotlinx` packages are libraries, not platform modules.
- Settings: `minSdk`, `targetSdk`, `compileSdk`, `jvmTarget`/`jvmToolchain`, and the Kotlin plugin version, read from build files and the version catalog.

## Acceptance criteria
- [ ] A Gradle fixture with an app module, a library module, and tests produces the expected components, test components, and edges, in both DSLs.
- [ ] Version catalog libraries are external dependencies with their versions.

## Constraints
No Gradle execution in name matching mode.
