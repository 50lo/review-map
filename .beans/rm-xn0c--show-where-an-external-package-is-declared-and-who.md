---
# rm-xn0c
title: Show where an external package is declared and who uses it
status: todo
type: task
tags:
    - ui
created_at: 2026-11-16T09:57:22Z
updated_at: 2026-11-16T09:57:22Z
parent: rm-w7ge
---

## What

Make the side panel for an external package say what the reviewer needs to judge the dependency change. Today it says almost nothing.

**Observed:** selecting the removed package `@tauri-apps/cli` in a review of base `0cd5916` against head `0e57fa4` of this repository shows only:

- the name
- "external package · removed"
- "Package removed"

The rest of the sidebar is empty. `ComponentPanel` in `app/src/Sidebar.tsx` renders this:

- The "Depends on" and "Used by" lists are empty when no edges reach the package. That is the case for a dev-only tool and during the preliminary stage.
- It shows the package's findings only through the generic Findings section.

**Expected:** the panel answers these questions:

1. **What changed.** Added, removed, or bumped, with the versions (`ExternalDepChange.from` and `to`). This is shown today.
2. **Where it is declared.** The manifest or lockfile entries at base and head, e.g. `app/package.json`, `MODULE.bazel`, `pnpm-lock.yaml`. Each comes with an Open button (the existing `OpenButton` in `app/src/Pages.tsx`), so the reviewer can see the diff lines.
3. **Who uses it.** Components that depend on it at head, and for a removed package, at base. Use the existing edges (`componentEdges`). When there are none, say so in words, e.g. "No code in the review scope imports it; it may be a build or dev tool." While the analysis is still preliminary, say that users are not known yet instead of showing an empty list.
4. **Its findings**, with their messages. The `new-external` message already names the components that now depend on the package.

**Report change needed for point 2.** The core doesn't record where a pin comes from today.

- `diff_external_deps` in `crates/core/src/analyze/finish.rs` (around line 151) collects pins from each language's `pinned_packages(source)` and from every `MODULE.bazel`, and keeps only name → version.
- Add an optional field to `ExternalDepChange` in `crates/core/src/model.rs` and in `app/src/types.ts`:

```ts
// app/src/types.ts
export interface ExternalDepChange {
  name: string;
  change: "added" | "removed" | "bumped" | string;
  from?: string;
  to?: string;
  /** Where the pin is declared at each side. Missing in reports made before this field existed. */
  declaredIn?: Array<{ side: "base" | "head"; file: string; line?: number }>;
}
```

```rust
// crates/core/src/model.rs
pub struct ExternalDepChange {
    pub name: String,
    pub change: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty", rename = "declaredIn")]
    pub declared_in: Vec<DeclaredIn>, // { side, file, line: Option<u32> }
}
```

The field is additive and optional, so the report version doesn't change. `pinned_packages` (or a new sibling) has to return the file, and the line where it can be found cheaply.

## Why

A dependency change is reviewed by asking where it came from, who needs it, and whether it is safe. The panel answers none of these today. The reviewer has to leave the app and search the manifests and lockfiles by hand, which defeats the point of a structural review.

## Where

- `crates/core/src/analyze/finish.rs`: `diff_external_deps`.
- Each language's `pinned_packages` in `crates/core/src/lang/`, and `bazel::module_deps`.
- `crates/core/src/model.rs`: `ExternalDepChange`.
- `app/src/types.ts`, `app/src/Sidebar.tsx` (`ComponentPanel`, or a dedicated `ExternalPanel`), `app/src/Pages.tsx` (`OpenButton`).

## Acceptance criteria

- [ ] For an added, a removed and a bumped package, the panel shows the change, the files where the package is declared at each side with working Open buttons, its users (or a sentence saying there are none or that they are not known yet), and its findings.
- [ ] A report without `declaredIn`, from before this change or from the dev mock, still renders. The panel then shows no "declared in" section.
- [ ] Rust tests in `crates/core/tests/` cover `declaredIn` for a Yarn Classic `package.json` and lockfile, a `MODULE.bazel` `bazel_dep`, and a rules_js `pnpm-lock.yaml`. Use the existing fixtures under `crates/core/tests/fixtures/` where they have such changes.
- [ ] `bazel test //...` passes.

## Dependencies and constraints

- Rule CORE-002 "Analysis never writes into the reviewed repo": read committed content only, as the rest of the core does.
- Run `statute show` on `crates/core/src/model.rs`, `crates/core/src/analyze/finish.rs` and the language files before changing them. `model.rs` is linked to CORE-001.
- The task "Group changed external packages into one map node" (rm-8byb) in this epic adds a group panel that links to this panel. The two can be done in either order.
- Epic: UI improvements (rm-w7ge).
