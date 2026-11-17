---
# rm-we3p
title: Point build settings review items at the changed setting, not line 1 of the manifest
status: completed
type: bug
priority: normal
tags:
    - core
created_at: 2026-11-16T21:36:10Z
updated_at: 2026-11-17T22:15:01Z
---

## What

Make the code shown for a target's "build settings" review item point at the setting that changed, not at line 1 of the target's manifest. Today `Builder::add_target_settings` in `crates/core/src/analyze/finish.rs` gives every build-settings review item the location `Location { file: <target settings file>, start_line: 1, end_line: 1, side: Head }`, whatever key changed and whichever file the key lives in. The region builder (`RegionBuilder::regions` in `crates/core/src/analyze/regions.rs`) then makes one region over that location: a single line, usually `{` (package.json) or the first line of a BUILD file.

The "target settings file" (`TargetSettings.file`, `crates/core/src/analyze/components.rs`) is:
- for an npm package or tsconfig project (`crates/core/src/lang/typescript/mod.rs`, `TypeScriptLanguage::add_components`): the package's `package.json`, even for keys `"tsconfig <compiler option>"` that live in the package's `tsconfig.json`;
- for a Bazel target of any language (Swift, Kotlin, TypeScript under rules_ts; `add_targets` in `components.rs`): the target's BUILD file. The attribute (`copts`, `swiftcopts`, `kotlinc_opts`, ...) is somewhere in the target's rule, never reliably on line 1. The rule's line is known from `bazel query` (`rule.location`, "BUILD.bazel:3:14") but `node_of` in `crates/core/src/bazel/query.rs` drops it.

## Why

Every region on a review item page should be worth reviewing. A one-line `{` from the wrong file wastes the reviewer's attention and hides the real change (the `noEmit` line in tsconfig.json). The page header ("app/package.json:1") also sends the reviewer, and "Open in Xcode", to the wrong file.

## Where

- `crates/core/src/analyze/finish.rs` — `add_target_settings` (item location, ids, names).
- `crates/core/src/analyze/regions.rs` — `RegionBuilder::regions`, the branch for `ItemKind::File` / `ItemKind::Target` items.
- `crates/core/src/analyze/components.rs` — `TargetSettings` (where each key is set), `add_targets` (Bazel).
- `crates/core/src/lang/typescript/mod.rs` — where the TypeScript settings are collected (`package.json <field>`, `tsconfig <option>`).
- `crates/core/src/bazel/query.rs`, `crates/core/src/bazel/graph.rs` — `TargetNode` and the rule's line.
- UI: `ReviewItemPageInner` in `app/src/Pages.tsx` renders ONE file (`e.location.file` on `e.location.side`) and places every region at `region.startLine - location.startLine`, so every region of an item must be in the item's location file.

## Observed

Reported by the user on 2026-11-17 in the Review Map app, reviewing this repository from base `0cd5916` to head `0e57fa4`. Review item page "reviewmap-app build settings" (target in reviewmap-app, change `modifiers`, interface):
- signature `tsconfig noEmit = true`, flag "compiler options changed";
- CODE section: `app/package.json:1`, "1 region to review", the region is line 1 of `app/package.json`: `{`, risk 0.37.

## Expected

- The code shown is the setting that changed: for `tsconfig noEmit` the `"noEmit": true` line of `app/tsconfig.json` (`git diff 0cd5916 0e57fa4 -- app/tsconfig.json` adds that one line); for a `package.json` field, that field's line in `package.json`; for a Bazel attribute, the attribute's line in the target's rule in the BUILD file.
- If a setting's line can't be found, the item still points at the right file (and, for Bazel, at the target's rule), never at line 1 of another file.

## Repro

1. Build the app bundle with `scripts/build-app.sh`; the CLI is `bazel-out/darwin_arm64-opt/bin/app/Review Map.app/Contents/MacOS/reviewmap`.
2. `REVIEWMAP_HOME=<scratch dir> reviewmap . --base 0cd5916 --head 0e57fa4 --report <scratch>/report.json`.
3. Find the review item with `qualifiedName` "reviewmap-app build settings" and its regions.

Note: the item appears only when Bazel is not found (set `REVIEWMAP_BAZEL=reviewmap-no-such-bazel` to reproduce it in a shell that has Bazel; an app launched from Finder may not have Bazel on its PATH). With Bazel, the files under `app/` at head belong to the Bazel targets `//app:ts` and `//app:dist`, so `TypeScriptLanguage::add_components` skips the npm package `reviewmap-app` at head and there is no build settings item to compare.

## Acceptance criteria

- For an npm package whose tsconfig.json gains `"noEmit": true`, the build settings review item's location is in `tsconfig.json`, and its region covers exactly the `"noEmit"` line.
- For a changed `package.json` field (e.g. `types`, with an `exports` block holding a nested `"types"` key earlier in the file), the region is the top-level field's line, not the nested one.
- When both package.json and tsconfig settings of one target change, each file gets its own review item, so every region is in its item's file (no report format change).
- A removed setting is shown on the base side at its base line.
- A Bazel target's changed attribute points at the attribute's line in the target's rule (falls back to the rule's line, then to the BUILD file).
- Each region names only its own setting's flag.
- New core tests fail before the fix and pass after it; `bazel test //...` passes.

## Dependencies and constraints

- Statute rules CORE-005 (every finding points at something on the map) and CORE-006 (formatting-only changes ask for no review) must keep holding.
- The report format (`app/src/types.ts`) should not change; if it must, say so and update the UI.
- The Rust tests that compare against the prototype's `expected.json` fixtures (`tests/ReviewMapCoreTests/Fixtures/*`) compare edges and contract flags, not locations.

## Summary of Changes

**Cause.** `Builder::add_target_settings` (`crates/core/src/analyze/finish.rs`) set every build settings review item's location to line 1 of `TargetSettings.file`: the package.json for npm packages (even for `tsconfig <option>` keys, which live in tsconfig.json) and the BUILD file for Bazel targets. `RegionBuilder::regions` (`crates/core/src/analyze/regions.rs`) turned that location into the one region, scored by all the item's flags (0.37 for `compiler-options-changed`). The same applied to Swift, Kotlin and TypeScript Bazel targets (`copts`, `kotlinc_opts`, ...), always shown at line 1 of the BUILD file.

**Fix.**
- `TargetSettings` (`crates/core/src/analyze/components.rs`) now records where each key is set: `key_files` (key → file, for keys not in `file`; TypeScript fills it with the project's tsconfig.json for `tsconfig <option>` keys) and `rule_line` (the line of the Bazel rule). `file_of(key)` returns a key's file.
- `TargetNode.build_line` (`crates/core/src/bazel/graph.rs`, `#[serde(default)]`) keeps the line from `bazel query`'s `rule.location` ("BUILD.bazel:3:14"), which `node_of` in `query.rs` used to drop.
- New `crates/core/src/analyze/settings.rs`: `setting_lines(text, key, rule_line)` finds the lines of a setting and its whole value, so a multi-line `copts = [...]`, `"lib": [...]` or `"exports": {...}` is shown whole, not as its opening line. It finds a top-level package.json field, a `compilerOptions` key in tsconfig (a JSONC scanner that skips strings, comments, nested objects and arrays), or an attribute inside the Bazel rule's call.
- `add_target_settings` makes **one review item per file** that sets a changed setting. The id stays `<file>::<component> build settings`, now with the setting's file. The name stays `<target> build settings` when one file changed, and becomes `<target> build settings (<file name>)` when several did. Location: the head lines of the changed settings in that file. A setting removed from a file that still exists is a `removed` region at its base line, anchored after the head line it followed (the same LCS rule the UI's `lineChanges` uses), and the item gets a `baseLocation` over the base lines. A file gone at head is shown on the base side. A line that can't be found falls back to the Bazel rule's line, then to line 1 of the setting's own file.
- `RegionBuilder::regions` makes one region per setting (its key through the end of its value) from `Builder::setting_spots`, each scored and labelled by only its own settings' flags.

**Report format.** Unchanged (`app/src/types.ts` untouched). Behaviour that changed: build settings items have new ids when their settings are in another file than the manifest (review marks and notes keyed by the old id don't carry over), and a target whose settings changed in two files has two items.

**Tests.** `crates/core/tests/typescript_fixtures.rs`: `a_changed_tsconfig_option_is_shown_at_its_line_in_tsconfig` and `build_settings_in_two_files_are_shown_where_each_is_set`. Both failed before the fix (location `("app/package.json", 1, 1)`; one item instead of two) and pass after. `a_setting_written_over_several_lines_is_shown_whole` (an entry added inside a multi-line `lib` array: the region runs from `"lib"` to its `]`). `crates/core/tests/bazel_fixtures.rs`: `a_changed_bazel_attribute_is_shown_at_its_line_in_the_rule` (swift-bazel fixture, Feed's `copts` changed). Unit tests are in `settings.rs`, and `reads_a_rule` in `bazel/query.rs` now asserts `build_line`. `the_prototype_fixture_keeps_its_dependencies_and_contract_flags` now compares a prototype "X build settings" item's flags with the union of the rebuild's per-file items for that target.

## What was checked

- `bazel test //...`: 9 of 9 targets pass, including the Bazel fixture tests (run again after the multi-line change).
- The real repro: `reviewmap . --base 0cd5916 --head 0e57fa4` in this repository with `REVIEWMAP_BAZEL=reviewmap-no-such-bazel` and a scratch `REVIEWMAP_HOME`. The app bundle built from `200fe5e` (before the fix) gives "reviewmap-app build settings" at `app/package.json:1-1` with one region `app/package.json:1`, risk 0.37, `compiler-options-changed`: the user's observation. The fixed CLI gives the item at `app/tsconfig.json:8-8` with one region on that line (`"noEmit": true,`), same risk and reason. It is the only build settings item in either report.
- A fresh CLI report on a scratch repo holding this repository's `app/package.json` and `app/tsconfig.json` at `0cd5916` (base) and `0e57fa4` (head). Before the fix (the app bundle built from `200fe5e`): "reviewmap-app build settings" at `app/package.json:1-1`, one region `app/package.json:1`, risk 0.37, the user's exact observation. After: the item is at `app/tsconfig.json:8`, with one region on that line (`"noEmit": true,`), risk 0.37, reason `compiler-options-changed`.
- Dev preview (`REVIEWMAP_REPORT=... bazel run //app:dev`) of a report with package.json `types` changed (with a nested `exports["."].types`) and tsconfig `strict` changed plus `noImplicitAny` removed. Two items, "(package.json)" at line 9 (the top-level `types`, not the nested one at line 5) and "(tsconfig.json)" at line 3 with a `strict` region and a removed region whose marker expands to `"strict": false,` and `"noImplicitAny": true,`.
- `statute check`: no stale or missing links. No symbol linked to a rule changed. CORE-006 still holds because settings are compared by value, so reformatting a manifest changes no key. CORE-005 is unaffected because no finding anchors changed.

## Not checked

- With Bazel available, the repro command produces no build settings item (see Repro). Whether the user's app run lacked Bazel for the same reason was not confirmed with the user.
- The dev preview was checked before the multi-line change; the UI code is unchanged and a multi-line region renders as any multi-line code region does.
- The Bazel test was not run against the pre-fix code. The old code sets line 1 for every build settings item, so it would fail.
- Kotlin Bazel targets are covered only through the shared attribute finder (same code path as Swift); no Kotlin fixture changes a setting.

## Follow-ups found (not fixed here)

- A Bazel target that gains its **first** setting (or loses its last) gets no build settings item: `add_targets` in `components.rs` registers `TargetSettings` only when the target has settings (`if !t.settings.is_empty()`), and `add_target_settings` skips targets missing at either side. TypeScript registers empty settings on purpose for this reason.
- A change that touches only BUILD files puts no Bazel workspace in scope when the review has no `cwd` (`Session::open` in `session.rs` counts only changed source files). The CLI and app pass a cwd, so this affects library callers and tests only.


## Tests removed (2026-11-18, test-suite cleanup)

To cut `bazel test //...` time, three of the tests above were removed as location details that unit tests already cover: `a_changed_tsconfig_option_is_shown_at_its_line_in_tsconfig` and `a_setting_written_over_several_lines_is_shown_whole` (`crates/core/tests/typescript_fixtures.rs`), and `a_changed_bazel_attribute_is_shown_at_its_line_in_the_rule` (`crates/core/tests/bazel_fixtures.rs`, which started two nested Bazel servers). The line lookup each guarded stays tested in `crates/core/src/analyze/settings.rs` (`a_tsconfig_option_is_a_key_of_compiler_options`, including the multi-line `lib` array, and `a_bazel_attribute_is_found_in_its_rule`), and the end-to-end path stays tested by `build_settings_in_two_files_are_shown_where_each_is_set`.
