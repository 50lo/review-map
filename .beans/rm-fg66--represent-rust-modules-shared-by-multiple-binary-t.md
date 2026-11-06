---
# rm-fg66
title: Represent Rust modules shared by multiple binary targets
status: todo
type: bug
created_at: 2026-11-06T21:24:25Z
updated_at: 2026-11-06T21:24:25Z
---

The rm-z9rn Crossbeam run (a28f40fdddb70bea8e5faf0efad9af0be4b9dbea) found false binary-to-binary source edges: benchmark binaries each declare mod message, sharing crossbeam-channel/benchmarks/message.rs. The current one-file/one-component mapping assigns message.rs to the first binary (atomicring), so calls to message::new in other binaries look like dependencies on atomicring. Manifest dependencies with the same name as a binary were fixed separately. Define target-aware ownership for shared Rust source files and test that a shared local module does not create dependencies between independent binaries. Both name and indexed references must retain target ownership.
