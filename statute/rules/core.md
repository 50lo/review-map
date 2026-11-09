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
agreed: agreed            # proposed | agreed | retired
built: built              # planned | built
scope: "Analyzer.run, GitRepo.export, index builds, and the LLM annotator's cache."
terms: [Change, Change report]
exceptions:
  - "A path the user names with -o is written even if it is inside the repository."
protects:
  - "An LLM cache directory inside the repository is refused with an error."
  - "Uncommitted files in the working tree stay as they are and are not analyzed."
boundary:
  - "reviewmap.yml is read from the head commit's tree, not from the working tree."
```

# CORE-003 References matched by name always come with a warning

When references in a language are matched by name instead of resolved through that language's index, the change report carries a warning that names the language: `index-unavailable` when no index could be built, `index-partial` with the uncovered files when the index missed some of them.

```yaml
agreed: agreed            # proposed | agreed | retired
built: built              # planned | built
scope: "Index mode in Analyzer.run and ChangeReportBuilder.addIndex, for every language."
terms: [Change report, Dependency]
exceptions: []
protects:
  - "A failed index build falls back to name matching and adds an index-unavailable warning for that language."
  - "Files with no index data are matched by name and listed in an index-partial warning."
boundary:
  - "The warning carries this guarantee, not analyzer.resolution, which reads index when any language was indexed."
  - "With index mode off, the whole report is name-based (analyzer.resolution is name-based) and no index warning is added."
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
