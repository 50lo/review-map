---
# rm-jf7h
title: Show Rust in the viewer
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-wa33
---

## Implementation scope
Add the Rust entry to the viewer's language table: `.rs` files, `Cargo.toml` and `Cargo.lock`, the `cargoCrate` kind, an icon, Shiki's `rust` language, and kind names (protocol -> trait, extension -> impl, case -> variant, func -> fn, typealias -> type, var -> field, const, or static).

## Acceptance criteria
- [ ] Rust components show the Rust badge; code pages highlight Rust; entities show Rust's kind names.
- [ ] Checked in Chromium at desktop and phone widths, in light and dark mode, on a Rust fixture model.
