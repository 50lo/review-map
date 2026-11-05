---
# rm-nec5
title: Parse Go declarations and references
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:50:00Z
parent: rm-a4b7
---

Add tree-sitter-go and a `GoLanguage` with its extractor, so Go files produce declarations and name references.

## Implementation scope
- Add tree-sitter-go (v0.25.0 has a Package.swift exposing `TreeSitterGo`) to Package.swift with an exact version. Check that its ABI loads with tree-sitter 0.25.10.
- Sources/ReviewMapCore/Go/: `GoLanguage` (id `go`, `.go` files, generated patterns such as `*.pb.go`, `*_gen.go`, `zz_generated*.go`, and files with a `// Code generated ... DO NOT EDIT.` header) and `GoExtractor`.
- Declarations from a walk over the tree: types (struct -> struct, interface -> protocol, others -> typealias), functions, methods scoped to their receiver type (pointer or not), interface methods as requirements, constants, and variables. `access` is `public` for capitalized names, otherwise `internal`. Public API (rm-n95m's hook) is a capitalized declaration whose enclosing type is also capitalized.
- References are queries: `pkg.Name` selectors resolved through the file's imports (aliases, dot imports, `_` imports ignored), with `NameRef.module` set to the import path. Unqualified names refer to the same package.
- Register the language in `Languages.all`.

## Acceptance criteria
- [ ] A Go fixture pair under Tests/ReviewMapCoreTests/Fixtures/go parses into the expected declarations, kinds, scopes, and access.
- [ ] Changes are classified (added, removed, signature, body, modifiers, cosmetic) as for the other languages.
- [ ] Swift and TypeScript fixture results are unchanged.

## Constraints
Follow the TypeScript implementation in Sources/ReviewMapCore/TypeScript/ and its tests as the pattern.
