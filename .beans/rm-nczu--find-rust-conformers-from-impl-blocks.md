---
# rm-nczu
title: Find Rust conformers from impl blocks
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T21:20:58Z
parent: rm-wa33
---

## Implementation scope
Conformers of a trait are the `impl Trait for Type` blocks. When a trait gains a required item (one without a default body), every impl that lacks it at head is a finding; default methods count as implemented. A changed required signature flags impls whose item didn't change. Blanket impls (`impl<T: Bound> Trait for T`) are skipped.

Uses the conformance hook from rm-n95m only if the default inheritance-clause lookup can't express this; otherwise the extractor's `inherited` is enough.

## Acceptance criteria
- [x] A fixture trait that gains a required method produces a finding for the impl without it and none for an impl that has it or a trait with a default body.

## Summary of Changes

Added Rust explicit conformance lookup with witnesses scoped to each impl block. Defaults satisfy requirements; missing required items and unchanged implementations of changed signatures produce findings. Bare generic blanket impls are skipped while concrete generic types remain checked. Name-mode lookup distinguishes inline trait names and resolves cross-crate imports through Cargo dependency aliases, including multiline impl headers. Both conformance tests pass, covering missing versus complete impls, defaults, stale signatures, blanket/concrete generics, multiple impls for one type, scoped names, and renamed cross-crate dependencies.
