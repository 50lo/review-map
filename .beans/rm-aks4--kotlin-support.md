---
# rm-aks4
title: Kotlin support
status: completed
type: epic
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-07T01:13:40Z
---

Step 7 of docs/plan.md. Review Map analyzes Kotlin changes (JVM and Android projects built with Gradle), and is usable on real Kotlin PRs.

Kotlin has no indexer that works without a build, so it ships with name matching. Index mode is a separate measurement (rm-0ggn) before anything is built.

Order: rm-mfpz (parsing), rm-31f9 (components), rm-d63r (flags and risk), rm-c2og (structural review), rm-j0dk (viewer), then rm-ltol (small synthetic validation). Starts after Rust (rm-wa33) is usable. The user explicitly replaced real-project validation with small synthetic validation on 2026-11-07 to limit disk use; rm-0ggn is deferred outside this implementation. Keep CI minimal and run full tests locally. Clean up temporary development and validation artifacts.

## Summary of Changes

Completed Kotlin parsing, Gradle components/dependencies, flags and risk, structural review, viewer support, and small synthetic validation in separate task commits with independent reviews and follow-up fixes. The user-authorized scope excludes real-project validation and the deferred rm-0ggn indexing experiment. Final local evidence and known limits are recorded in docs/progress.md Step 7. CI remains limited to builds and smoke tests; temporary validation artifacts were cleaned and the original MODULE.bazel.lock edit remains untouched.
