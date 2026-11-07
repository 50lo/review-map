---
# rm-nozk
title: Avoid Rust test declarations competing with library names
status: todo
type: bug
created_at: 2026-11-06T21:22:32Z
updated_at: 2026-11-06T21:22:32Z
---

The Rust real-repository run (rm-z9rn) on Crossbeam a28f40fdddb70bea8e5faf0efad9af0be4b9dbea reports ambiguous-name for Receiver, Sender, and select on both sides because declarations in cargo:crossbeam-channel:tests compete with cargo:crossbeam-channel. Name matching should use Cargo target ownership and explicit imports to keep library imports distinct from same-name test declarations. Preserve honest ambiguity when source ownership is actually unclear. Index mode resolves covered references; add a focused library/test name collision fixture.
