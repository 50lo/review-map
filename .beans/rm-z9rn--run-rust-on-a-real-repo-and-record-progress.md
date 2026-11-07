---
# rm-z9rn
title: Run Rust on a real repo and record progress
status: completed
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-06T21:25:43Z
parent: rm-wa33
---

## Implementation scope
Run the analyzer on the last 40 commits of a mid-size open-source Cargo workspace with several crates and trait-heavy code, in both modes. Look for false links and noisy findings; fix them or file beans.

Record timings, results, and decisions in a "Step 6 notes" section of docs/progress.md, mark step 6 done, and list Rust as supported in README.md with its index mode requirements.

## Acceptance criteria
- [x] The run completes in both modes, and its results are described in docs/progress.md.
- [x] README.md lists Rust as supported.

## Summary of Changes

Validated the pinned final 40 commits of crossbeam-rs/crossbeam in name, rebuilt index, and cached index modes. Recorded per-side and total timings, report counts, findings, and partial-index limitations in docs/progress.md; documented Rust support and tool requirements in README.md. Fixed the discovered binary/external-package name collision in rm-9h2n. Filed remaining observed limits as rm-u71m (chained use aliases), rm-nozk (library/test name ambiguity), and rm-fg66 (source shared by binary targets). Cold and cached graphs/findings match.
