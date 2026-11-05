---
# rm-j0dk
title: Show Kotlin in the viewer
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-aks4
---

## Implementation scope
Add the Kotlin entry to the viewer's language table: `.kt` and `.kts` files, `settings.gradle(.kts)`, `build.gradle(.kts)`, `libs.versions.toml`, and `AndroidManifest.xml`, the `gradleModule` kind, an icon, Shiki's `kotlin` language, and kind names (protocol -> interface, func -> fun, var -> property, case -> entry, typealias -> typealias, and object).

## Acceptance criteria
- [ ] Kotlin components show the Kotlin badge; code pages highlight Kotlin; entities show Kotlin's kind names.
- [ ] Checked in Chromium at desktop and phone widths, in light and dark mode, on a Kotlin fixture model.
