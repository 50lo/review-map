---
# rm-u71m
title: Resolve Rust use paths through earlier import aliases
status: todo
type: bug
created_at: 2026-11-06T21:22:32Z
updated_at: 2026-11-06T21:22:32Z
---

The Rust real-repository run (rm-z9rn) on crossbeam-rs/crossbeam a28f40fdddb70bea8e5faf0efad9af0be4b9dbea reports unresolved imports for chained aliases: crossbeam-epoch/tests/loom.rs has use crossbeam_epoch as epoch followed by use epoch::{Atomic, Owned, *}; crossbeam-utils/tests/thread.rs uses thread::unix::JoinHandleExt after importing thread. Resolve use declaration prefixes through bindings already in scope, preserving original crate/module attribution. Add regressions for chained aliases and inner scopes. Existing Rust parsing covers directly renamed imports but not alias prefixes in later use declarations.
