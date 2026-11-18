---
# rm-47r1
title: A Bazel target's first or last build setting gets no build settings review item
status: todo
type: bug
tags:
    - core
created_at: 2026-11-17T09:46:55Z
updated_at: 2026-11-17T09:46:55Z
---

## What

A Bazel target that gains its first build setting, or loses its last one, gets no "build settings" review item. The change to the target's configuration never reaches the reviewer as something to review.

A build settings review item (`kind: target`, `change: modifiers`, `qualifiedName: "<target> build settings"`) is the review item the analyzer adds when a target that exists at both base and head has a setting whose value differs:
- For TypeScript/npm targets, a setting is a `package.json` field or a `tsconfig.json` compiler option.
- For Bazel targets (Swift, Kotlin and so on), a setting is an attribute on the target's rule in its BUILD file, such as `copts` or `defines`.

The item's signature lists the changed settings with their values on both sides, and its contract flags say what kind of change it is ("compiler options changed" and so on). Since rm-we3p, its region is the lines that set those settings.

### Cause

Two places in `crates/core/src/analyze/` combine to lose the change:

1. `add_targets` in `components.rs` (around line 337) records a Bazel target in `layout.target_settings` only when it has settings: `if !t.settings.is_empty() { layout.target_settings.insert(id, TargetSettings { … }) }`. A target with no tracked settings therefore has no entry at all on that side.
2. `add_target_settings` in `finish.rs` (around line 88) walks the head side's entries and skips any target with no base entry: `for (id, hs) in h { let Some(bs) = b.get(id) else { continue }; … }`.

As a result:
- **First setting added** (no settings at base, `copts = ["-Osize"]` at head): there is no base entry, so step 2 skips the target, and no item is made.
- **Last setting removed** (`copts` at base, no settings at head): there is no head entry. Step 2 walks only head entries, so the target is never looked at, and no item is made.

The TypeScript path doesn't have this problem. `crates/core/src/lang/typescript/mod.rs` (around line 314) registers a `TargetSettings` entry for every package, even one with no settings, so both sides always have something to compare.

### Observed

A change that adds the first `copts` (or `defines`, or any other tracked attribute) to an existing Bazel target that had none, or that removes a target's only tracked attribute, produces no build settings review item. The BUILD file's diff is still in the change, but it has no review item, region or flag.

### Expected

Either change produces a build settings review item, just as changing an existing setting does:
- When the first setting is added, the signature has no base value and the head value, and the region is the attribute's line at head.
- When the last setting is removed, the signature has the base value and no head value, and the region is the attribute's line at base (removed settings are already shown on the base side since rm-we3p).

A target that is itself added or removed still gets no build settings item. It already shows as an added or removed component.

### Repro

Use a Bazel fixture like the ones in `crates/core/tests/bazel_fixtures.rs`. At base, have a `swift_library` (or Kotlin target) with no tracked attributes. At head, give it `copts = ["-Osize"]`. Analyze the change: the report has no review item whose `qualifiedName` ends in "build settings" for that target. Do the reverse (copts at base, none at head) and get the same result.

## Why

A build setting can change how every file in a target compiles or behaves without any source line changing. A target's first flag is as likely to matter as a change to an existing one, and is often more surprising. Today exactly this case slips past the review.

## Where

- `crates/core/src/analyze/components.rs`, `add_targets`: register a `TargetSettings` entry for every Bazel code target, including one with empty `settings`, with the same `file` and `rule_line` it gets now. This matches what the TypeScript path does.
- `crates/core/src/analyze/finish.rs`, `add_target_settings`: should need no change once both sides have entries. It already compares the union of keys and skips a target whose settings are equal. Check that a target with empty settings on both sides makes no item.
- `crates/core/src/analyze/settings.rs` (from rm-we3p): finds the attribute's line. Check that it handles a setting present on only one side; for a removed setting, that means the base side.
- `crates/core/tests/bazel_fixtures.rs`: new cases.

## Acceptance criteria

- [ ] A Bazel target with no tracked settings at base and `copts` at head gets a build settings review item. Its signature has no base value and `copts` at head, its flag matches the attribute, and its region is the `copts` line at head.
- [ ] A Bazel target with `copts` at base and no tracked settings at head gets a build settings review item, with its region on the `copts` line at base.
- [ ] A Bazel target with no tracked settings on either side gets no build settings item.
- [ ] A Bazel target added or removed in the change gets no build settings item.
- [ ] Existing build settings behaviour, for Bazel and TypeScript, is unchanged. The rm-we3p tests still pass.
- [ ] New tests fail before the fix and pass after it. `bazel test //...` passes.

## Dependencies and constraints

- Builds on rm-we3p (merged into `rebuild` at 82494e3), which put build settings items at the line that sets them.
- No change to the report format.
- Run `statute show` on the files you touch before changing them, and the `statute:change` skill after. Rules are in `statute/rules/core.md`.
- Related, out of scope: when a change touches only BUILD files and the review has no working directory, no Bazel workspace is in scope (`Session::open` in `session.rs`). That affects only library callers and tests, since the CLI and the app always give a working directory.
