---
prefix: CORE
---

Rules for how the analyzer turns a change into a change report.

# CORE-001 A change is measured from the merge-base

By default, the base of a change is the merge-base of the base ref and the head, which is what a pull request shows. The change report records the commits it compared (`baseSha`, `headSha`) and whether the base is the merge-base (`usesMergeBase`).

```yaml
agreed: agreed            # proposed | agreed | retired
built: built              # planned | built
scope: "Analyzer.run and the RepoInfo it writes into every change report."
terms: [Change, Change report]
exceptions: []
protects:
  - "main gains a commit after the branch was cut: the change does not show that commit's code as removed by the branch."
boundary:
  - "With --no-merge-base the base is the base ref itself, and usesMergeBase is false."
```

# CORE-002 Analysis never writes into the reviewed repo

Analyzing a change reads the reviewed repository and writes nothing into it: not its working tree, its index, its refs, or `.git`. The base and head are exported to a temporary directory, index builds run in those copies, and the change report, caches and indexes go outside the repository.

```yaml
agreed: proposed          # proposed | agreed | retired
built: built              # planned | built
scope: "Analyzer.run, GitRepo.export, index builds, and the LLM annotator's cache."
terms: [Change, Change report]
exceptions:
  - "A path the user names with -o is written even if it is inside the repository."
protects:
  - "Uncommitted files in the working tree stay as they are and are not analyzed."
boundary:
  - "reviewmap.yml is read from the head commit's tree, not from the working tree."
```

# CORE-003 Without an index, a language shows only what syntax proves, and the report says so

The main change report never matches references by name. A language whose references are not resolved through its index (no index could be built, indexing was cancelled, or indexes are turned off) ends syntax-only: its final report shows the same links as the preliminary view, only those that syntax proves (an import that names one module or one declaration, and dependencies that BUILD files declare), and an `index-unavailable` warning names the language and the reason. Files an index misses at either side are syntax-only in the same way and are listed in an `index-partial` warning. The checks that claim no callers or no test references (`unused-api`, `orphaned`, `untested`) run for a language only when its index covers every file of that language that could hold such a reference; otherwise the report names the checks that did not run and why: in the `index-unavailable` warning for a language without an index, and in a `checks-held-back` warning for a partial index. References matched by name appear only in the comparison report the user asks for, whose `analysis.variant` is `name-based`.

```yaml
agreed: agreed            # proposed | agreed | retired
built: built              # planned | built
scope: "Session::report and Session::build, Builder::add_index and Builder::resolve_references, the coverage of the structural checks, and region context, for every language. The comparison report is outside it."
terms: [Change report, Dependency]
exceptions: []
protects:
  - "An index build that fails or is cancelled leaves the language with links from imports and declared dependencies only, and an index-unavailable warning that names the language and the reason. No call is linked by name."
  - "With indexes turned off, the report is syntax-only with an index-unavailable warning, not name-based."
  - "A file the index covers at only one side gets no name-matched links and is listed in an index-partial warning."
  - "A new public function whose only caller is in a file the index misses is not reported as unused-api, and the report says that unused-api was held back."
boundary:
  - "While a language's index is still to come, its resolution is preliminary and no index warning is added for it. Once it is known there will be none (the build failed, indexing was cancelled, or indexes are off, which is known from the first report), its resolution is syntax, whatever the report's stage."
  - "Coverage for the checks is judged per language at head, over every file of the language: its non-test files (generated ones included) for unused-api and orphaned, and its test files for untested. A file the index misses anywhere in the repository holds them back, even in another Bazel workspace or outside the review scope."
  - "index-partial lists the non-test, non-generated files the index misses; checks-held-back gives the counts that held the checks back."
  - "analyzer.resolution reads index when any language was indexed, so the per-language warnings carry this guarantee."
  - "The comparison report (analysis.variant name-based) matches every reference by name, runs every check on name occurrences, and carries no index warning."
```

# CORE-004 A failed LLM reply keeps the deterministic report

The analyzer produces a complete change report without the LLM. When an LLM reply fails validation or the call fails, the reply is dropped, the deterministic scores and data stay, and the change report records it with an `llm-rejected` warning. A rejected annotation batch also counts in `llm.failed`; a rejected structural review sets `llm.review` to `rejected` instead.

```yaml
agreed: agreed            # proposed | agreed | retired
built: built              # planned | built
scope: "Annotator.run and the structural review's LLM pass."
terms: [Change report, Review item, Region, Finding]
exceptions: []
protects:
  - "One rejected batch leaves the other batches' summaries and every deterministic score in place."
  - "A rejected structural review adds no LLM findings and keeps the deterministic ones."
boundary:
  - "When the LLM CLI is missing, the report is the same as with --no-llm, plus an llm-unavailable warning."
```

# CORE-005 Every finding points at something on the map

Every finding cites evidence and is anchored to at least one component, dependency or review item that exists in the same change report.

```yaml
agreed: agreed            # proposed | agreed | retired
built: built              # planned | built
scope: "Deterministic checks (Checks) and the LLM structural review (StructuralReview.validate)."
terms: [Finding, Component, Dependency, Review item, Change report]
exceptions: []
protects:
  - "An LLM finding that names an unknown review item, component or dependency, or no anchor at all, is rejected."
boundary:
  - "When a deterministic check's declaration has no review item in the report, the finding is anchored to its component."
```

# CORE-006 Formatting-only changes ask for no review

A review item whose only difference is formatting stays in the change report with change `cosmetic`, but it gets no regions, is not counted as changed, and is not passed to the checks or the structural review.

```yaml
agreed: agreed            # proposed | agreed | retired
built: built              # planned | built
scope: "Change classification in ChangeReportBuilder, region building, component scores, checks and structural review input."
terms: [Review item, Region, Change report]
exceptions: []
protects:
  - "A commit that only reformats a function does not add regions or raise its component's change count."
boundary:
  - "A container declaration (a type or extension) is never marked cosmetic; formatting inside it is judged member by member."
```
