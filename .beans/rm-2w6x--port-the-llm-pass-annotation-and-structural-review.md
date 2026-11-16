---
# rm-2w6x
title: Port the LLM pass (annotation and structural review) to the rebuild
status: completed
type: feature
priority: normal
created_at: 2026-11-16T06:18:50Z
updated_at: 2026-11-16T06:45:46Z
---

## What

Port the prototype's optional LLM pass to the rebuild's Rust core and wire it into the app and the `reviewmap` command. The prototype has it in `Sources/ReviewMapCore/Annotator.swift` and `Sources/ReviewMapCore/StructuralReview.swift`. The rebuild's UI can already show what it produces (`app/src/types.ts`: `llm` on the report, components, review items and regions, and findings with `source: "llm"`), but nothing in `crates/core`, `crates/cli` or `app/src-tauri` calls an LLM today, so those fields are never set.

The LLM pass has two parts, both run through a coding-agent CLI (`claude -p --output-format json --tools "" --no-session-persistence`, or `codex exec --skip-git-repo-check --sandbox read-only --color never --output-last-message <file> -`), with the prompt on stdin, in an empty temporary directory:

1. **Annotation**, one batch or more per component (whole review items, up to about 60,000 characters of material per batch). For each review item that is not cosmetic, test or generated, outside test components: a risk from 0 to 1 for every review and removed region, keep/rank for every context region, and a one-line summary. The first batch of a component also asks for the component's summary. The prompt ends with a `<reply-template>` JSON skeleton in which every id is filled in and the values are `"risk": null`, `"keep": null, "rank": null` and `"summary": ""`.
2. **Structural review**, one call for the whole change. Its prompt starts with `You are reviewing the structure` and lists the change description (pull request title and body from `gh pr view <head>`, else the commit messages), the changed components under `## Components` (one `- <component id> "<name>": …` line each), changed edges, the interface diff, usage, similar declarations, the deterministic findings, and the changed code. The reply is up to 12 findings of kind intent, placement, missing, duplicate or complexity, each anchored to a review item, a component or an edge that exists in the report.

Every reply is parsed (the outermost `{…}` of the text, so prose around it is accepted) and validated strictly against the report: the same review items and region ids, risks within 0…1, one-line summaries of at most 200 characters, ranks from 1 for kept context. A reply that fails gets one retry with the errors appended. Accepted results are cached by a hash of everything the LLM saw (prompt version, tool, model, `REVIEW.md` of the head commit, the review item's block), so a second review of the same change makes no calls. The repository's `REVIEW.md` at the head commit, when there is one, is included in both prompts.

## Why

`docs/rebuild-phase1-proposal.md` keeps the prototype's optional LLM assistance in phase 1: "Preserve the supported languages' existing contract checks and optional LLM assistance; a deterministic review must work independently of LLM completion." Rule CORE-004 (`statute/rules/core.md`, "A failed LLM reply keeps the deterministic report") is the only core rule still linked to the prototype's Swift code and tests, because the rebuild has no LLM pass to link it to. Without this work the rebuild can't rank regions or summarize review items with an LLM, and CORE-004 has no Rust implementation or acceptance test.

## Where

- New `crates/core/src/llm/` module in the Rust core, with `llm::Annotator::run` as the entry point (CORE-004's scope says "Annotator.run and the structural review's LLM pass").
- `crates/core/src/model.rs`: optional `llm` fields, matching `app/src/types.ts` (report version stays 5; the fields are additive and optional).
  - `ChangeReport.llm: Option<LlmRun>`: `tool`, `model?`, `command?` (file name only), `promptVersion`, `batches`, `cached`, `failed`, `reviewNotes`, `review?` ("ok", "cached", "rejected" or "skipped"), `description?` ("pr" or "commits").
  - `Component.llm` and `ReviewItem.llm: Option<LlmSummary { summary }>`.
  - `Region.llm: Option<RegionLlm { risk?, keep?, rank? }>`.
  - `Finding.source` is `"llm"` for the structural review's findings.
- `crates/core/src/session.rs`: `ReviewRequest.llm: Option<LlmOptions>`. `None` means the LLM pass doesn't run. `LlmOptions` (camelCase in JSON): `tool` ("claude" or "codex", default "claude"), `command?` (an executable to run instead of the tool, such as the fake), `model?`, `jobs` (default 4), `timeoutSecs` (default 300), `maxBatchChars` (default 60,000), `structuralReview` (default true), `pullRequest` (ask `gh` for the head branch's pull request, default true), `cacheDir?` (default `<cache root>/llm`, which must be outside the reviewed repository).
- `crates/cli/src/main.rs` and `launch.rs`: `--llm <claude|codex>`, `--llm-command <path>`, `--llm-model <name>` and `--no-llm`, passed to the app; with `--report`, the LLM pass runs in-process when `--llm` or `--llm-command` is given.
- `app/src-tauri/src/lib.rs` and `settings.rs`: an `llm` entry in `settings.json` turns the pass on for every review; the launch flags override it. The app runs the pass after the analysis is complete, shows its progress, keeps the deterministic report on screen while it runs, and stops it on cancel.
- `scripts/fake-llm.sh`: the stand-in for both CLIs, and the only LLM the tests run.
- Tests: `crates/core/tests/core_rules.rs` (CORE-004), a new `crates/core/tests/llm.rs`, unit tests in the module, and `crates/core/BUILD.bazel`.
- `README.md` and `docs/rebuild-build.md`.

## Decisions

- **Testing uses only `scripts/fake-llm.sh`; no build or test may call a real coding agent**, because real calls cost money (the user's instruction, 2026-11-16). The fake imitates both CLIs' output and has the modes `ok`, `prose`, `invalid`, `fail` and `error` (`FAKE_LLM_MODE`). The prompt and reply format therefore stays the prototype's, so the fake works unchanged.
- **The core never chooses an LLM by itself.** `ReviewRequest.llm` is `None` unless a caller sets it, so a test that doesn't ask for the LLM can't start one, even when `claude` is on the `PATH`.
- **The app's default is off.** The prototype ran `claude` by default; in the rebuild the pass runs only when `settings.json` has an `llm` entry or the launch says `--llm`. This keeps manual testing of the app free, and the proposal calls the LLM assistance optional.
- **The LLM pass runs after the analysis is complete** (indexes done or final without them), on the final report, so its ids are final. The comparison report stays name-based and unannotated.

## Acceptance criteria

- [x] `llm::Annotator::run` annotates a review with the fake as `claude` and as `codex`: every eligible review item and every component with eligible review items gets a summary, every review and removed region a risk in 0…1, every context region keep (and a rank from 1 when kept), and the structural review adds its findings with `source: "llm"`.
- [x] CORE-004 holds and has Rust acceptance tests: a rejected batch leaves the other batches' results and every deterministic score in place and counts in `llm.failed`; a rejected structural review adds no LLM findings, keeps the deterministic ones and sets `llm.review` to `rejected`; both add an `llm-rejected` warning; a failing CLI keeps the deterministic report; a missing CLI leaves the report as without the LLM plus an `llm-unavailable` warning.
- [x] Replies wrapped in prose are accepted; a second run of the same change comes from the cache without running the CLI; a cache directory inside the reviewed repository is refused; cancelling stops the CLI.
- [x] The app and `reviewmap` can turn the pass on and off as described above.
- [x] CORE-004's links point at the Rust code and tests instead of the prototype's Swift.
- [x] `bazel test //...` passes, and no test runs a real `claude` or `codex`.
- [x] README.md says how to turn the LLM pass on and that it is off by default.

## Dependencies and constraints

- Must not break CORE-001 to CORE-006 or their tests. CORE-002: the cache and the CLI's working directory are outside the reviewed repository, and sources are read from the commits, never the working tree. CORE-005: every LLM finding is anchored to a component, edge or review item in the report.
- The prototype (`Sources/`, `Tests/`) stays as it is.

## Done (2026-11-16)

- `crates/core/src/llm/` (`mod.rs`, `batch.rs`, `review.rs`, `cli.rs`) ports the prototype's annotator and structural review with the same prompt and reply format; `session::run` runs it on the final report when `ReviewRequest.llm` is set.
- Tests: `//crates/core:llm` (10 tests: claude and codex, ranking, prose, cache, cache inside the repo, prompt contents, reading from commits, cancel, no LLM without options), the CORE-004 tests and an LLM CORE-005 test in `//crates/core:core_rules`, and unit tests in the module. Every test runs `scripts/fake-llm.sh` or a wrapper around it. Mutating the pass to overwrite deterministic risks made three of these tests fail.
- Checked end to end with `reviewmap --report … --llm-command scripts/fake-llm.sh` on a two-component Kotlin repo. The app's launch flags and settings are covered by `//app/src-tauri:unit_tests`; the app window itself was not checked.
- CORE-004 is linked to the Rust code and tests (Swift links removed); CORE-005 and CORE-002 gained the LLM links.
- `bazel test //...` (9 targets) passes. Two fixes it needed: `.claude` added to `.bazelignore` (other sessions' worktrees broke `//...`), and `tools/bazel` takes its own directory off the `PATH` that Bazelisk gives it and hands over to the next `bazel` when `BAZEL_REAL` is unset (the Bazel fixture tests found the wrapper as `bazel` and failed).
- Open: CORE-002's protects case says a cache inside the repository "is refused with an error"; the rebuild refuses it with an `llm-unavailable` warning and keeps the review, which may need rewording through a decision.
