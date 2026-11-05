---
# rm-z9rn
title: Run Rust on a real repo and record progress
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-wa33
---

## Implementation scope
Run the analyzer on the last 40 commits of a mid-size open-source Cargo workspace with several crates and trait-heavy code, in both modes. Look for false links and noisy findings; fix them or file beans.

Record timings, results, and decisions in a "Step 6 notes" section of docs/progress.md, mark step 6 done, and list Rust as supported in README.md with its index mode requirements.

## Acceptance criteria
- [ ] The run completes in both modes, and its results are described in docs/progress.md.
- [ ] README.md lists Rust as supported.
