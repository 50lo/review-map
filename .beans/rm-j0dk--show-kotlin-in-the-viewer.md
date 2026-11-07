---
# rm-j0dk
title: Show Kotlin in the viewer
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-07T01:05:34Z
parent: rm-aks4
---

## Implementation scope
Add the Kotlin entry to the viewer's language table: `.kt` and `.kts` files, `settings.gradle(.kts)`, `build.gradle(.kts)`, `libs.versions.toml`, and `AndroidManifest.xml`, the `gradleModule` kind, an icon, Shiki's `kotlin` language, and kind names (protocol -> interface, func -> fun, var -> property, case -> entry, typealias -> typealias, and object).

## Acceptance criteria
- [x] Kotlin components show the Kotlin badge; code pages highlight Kotlin; review items show Kotlin's kind names.
- [x] Checked in Chromium at desktop and phone widths, in light and dark mode, on a Kotlin fixture report.

## Implementation notes

Added Kotlin source/script highlighting, Gradle and Android manifest recognition, module badges, declaration labels including companion objects, and the Simple Icons mark. All 108 viewer tests and the production build pass locally. Chromium validation passed on the synthetic CLI report at 1440x1000 and 390x844, in light and dark mode: Kotlin badges, interface/fun labels, highlighted Compose source, no page errors or horizontal overflow. Screenshots were visually inspected, then temporary browser artifacts were removed.
