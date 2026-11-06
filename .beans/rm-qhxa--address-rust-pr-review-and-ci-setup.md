---
# rm-qhxa
title: Address Rust PR review and CI setup
status: completed
type: task
priority: normal
created_at: 2026-11-06T23:35:50Z
updated_at: 2026-11-06T23:37:56Z
---

Review all PR #26 threads, fix confirmed issues with regression checks, push, resolve fixed threads and explain retained design choices. Preserve existing MODULE.bazel.lock edit.

## Summary of Changes

Fixed Rust module labels in the viewer, extracted shared module-file lookup with a component-pass parse cache, narrowed partial-index diagnostics, and installed curl/CA certificates before the CI Rust bootstrap. Retained independent-workspace discovery and the compact TOML Value adapter with documented reasoning in PR review replies.

Validation: 18 focused Swift tests pass, all 96 viewer tests and the production build pass, independent reviews clear, Statute and diff checks clean. Existing MODULE.bazel.lock edit preserved.
