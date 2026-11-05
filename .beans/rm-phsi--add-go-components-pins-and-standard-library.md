---
# rm-phsi
title: Add Go components, pins, and standard library
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-a4b7
---

Go code is grouped by package, and a package is a directory.

## Implementation scope
- Add a `goPackage` component kind to `ComponentKind` (Model.swift and viewer/src/types.ts).
- Find modules from `go.mod` files and `go.work`. Each directory with non-test `.go` files inside a module is a package component, named by its import path. Nested modules own their own directories.
- `_test.go` files go to the package's test component (`go:<import path>:tests`). `testdata` and `vendor` folders are skipped.
- Pins from `go.mod` `require` lines (direct and `// indirect`), keyed by module path. `package(ofModule:)` maps an import path to the longest pinned module prefix.
- Platform modules: an import path whose first element has no dot is the standard library.
- Settings: `go`, `toolchain`, and `replace` directives in `go.mod`.

## Acceptance criteria
- [ ] The fixture's packages, their test components, and the edges between them are as expected; an import of a third-party module is an external dependency with its pinned version.
- [ ] A `go.work` with two modules produces both modules' packages.
- [ ] Standard library imports are neither edges nor warnings.

## Constraints
Read `go.mod` as text; no Go toolchain needed outside index mode.
