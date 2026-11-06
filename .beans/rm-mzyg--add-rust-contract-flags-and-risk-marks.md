---
# rm-mzyg
title: Add Rust contract flags and risk marks
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T21:18:41Z
parent: rm-wa33
---

## Implementation scope
- `RustFlags`: `pub` API added, removed, or changed; trait items added or removed; enum variants added or removed and `#[non_exhaustive]`; serde derives and `#[serde(...)]` attributes on a type whose fields change (persisted or wire shape); `Send`/`Sync` bounds and `async` added or removed; visibility narrowed.
- `settingFlag` for features, edition, `rust-version`, and profiles, and `flagRisk` weights.
- Risk table as queries: `unsafe` blocks and functions (crash), `unwrap` and `expect` (crash), `panic!`, `todo!`, `unimplemented!`, `unreachable!` (crash), slice and map indexing (crash), `as` numeric casts (check), `block_on` and `std::thread::spawn` (concurrency), `Mutex::lock().unwrap()` (concurrency).
- `isViewCode` is false.
- Add the new flags to the viewer's `flagWeight`.

## Acceptance criteria
- [x] Fixture changes produce the expected flags and risk marks, each covered by a test.

## Summary of Changes

Added Rust API, trait, enum, serde shape, concurrency-bound and visibility contract flags, Cargo setting flags, syntax-query risk marks, and viewer ranking weights. Regression fixtures cover serialized named and tuple fields, private module API exclusions, all requested risk constructs, and settings. Three targeted Swift tests and 96 viewer tests passed; independent review fixes applied.
