---
# rm-jf7h
title: Show Rust in the viewer
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T21:14:35Z
parent: rm-wa33
---

## Implementation scope
Add the Rust entry to the viewer's language table: `.rs` files, `Cargo.toml` and `Cargo.lock`, the `cargoCrate` kind, an icon, Shiki's `rust` language, and kind names (protocol -> trait, extension -> impl, case -> variant, func -> fn, typealias -> type, var -> field, const, or static).

## Acceptance criteria
- [x] Rust components show the Rust badge; code pages highlight Rust; review items show Rust's kind names.
- [x] Checked in Chromium at desktop and phone widths, in light and dark mode, on a Rust fixture report.

## Summary of Changes

Added Rust to the viewer language table with Cargo manifests and component kind, the Simple Icons Rust mark, Shiki highlighting, and Rust declaration kind labels. Constants and statics use the current or removed signature. All 96 viewer tests and the production build pass. Checked the generated Rust parser fixture report in Chromium at 1440x1000 and 390x844, in light and dark modes: Rust badges, highlighted code, fn/field labels, navigation, no page errors, and no horizontal page overflow. Screenshots captured under /private/tmp/rust-*.png.
