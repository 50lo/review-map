---
# rm-wa33
title: Rust support
status: completed
type: epic
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T21:28:48Z
---

Step 6 of docs/plan.md. Review Map analyzes Rust changes with exact references, and is usable on real Rust PRs.

Order: rm-lnvs (parsing), rm-9h2n (components), rm-mzyg (flags and risk), rm-nczu (conformers), rm-l5kt (index mode), rm-jf7h (viewer), rm-z9rn (real repo). Starts after Go (rm-a4b7) is usable.

## Summary of Changes

Completed all seven child tasks with separate commits, independent implementation reviews, and final review fixes. Rust parsing, Cargo components/pins, flags/risks, trait conformers, rust-analyzer indexing, and viewer support are validated on fixtures and a pinned 40-commit Crossbeam range. Three observed name-matching limits are tracked in rm-u71m, rm-nozk, and rm-fg66.

Final validation: 114 Swift tests pass with AnnotatorTests excluded; 96 viewer tests and the production build pass; Chromium desktop/mobile light/dark checks pass; Beans and Statute checks pass. The full Swift run was interrupted while an unchanged Annotator subprocess test waited for process completion. Bazel was not validated. The pre-existing local MODULE.bazel.lock edit is preserved.
