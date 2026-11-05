---
# rm-mfpz
title: Parse Kotlin declarations and references
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:50:00Z
parent: rm-aks4
---

Add tree-sitter-kotlin and a `KotlinLanguage` with its extractor.

## Implementation scope
- Add tree-sitter-grammars/tree-sitter-kotlin (v1.1.0 has a Package.swift exposing `TreeSitterKotlin`) with an exact version. Check that its ABI loads with tree-sitter 0.25.10 and that it parses current Kotlin (context parameters, value classes, multi-dollar strings) well enough; fwcd/tree-sitter-kotlin is the fallback.
- Sources/ReviewMapCore/Kotlin/: `KotlinLanguage` (id `kotlin`, `.kt` and `.kts` files except Gradle scripts; `build/generated/**` is generated) and `KotlinExtractor`.
- Declarations: classes (data, sealed, enum, value, annotation, inner), interfaces (protocol), objects and companion objects, functions including extension functions (scoped to their receiver type), properties, enum entries (`case`), and type aliases. Visibility defaults to public. Record `suspend`, `inline`, `open`, `abstract`, `override`, `data`, `sealed`, `lateinit`, and `const` as modifiers, and annotations as attributes. Supertype lists go to `inherited`.
- Public API (rm-n95m's hook): a public declaration whose enclosing declarations are also public.
- Packages: each file records its `package` header. A Gradle module holds many packages, so the package is not the component's `module`: Gradle module components have no `module`, which keeps the core's visibility filter from hiding them. The core builds a package -> components table from the parsed files' headers and uses it for imports the way it uses `moduleComponent`: an import's package makes those components visible, draws the import edge, and narrows a reference's candidates, instead of an `unresolved-import` warning.
- References: imports (single, star, aliased), resolved through the package table, and names from the same package, which need no import.

## Acceptance criteria
- [ ] A Kotlin fixture pair under Tests/ReviewMapCoreTests/Fixtures/kotlin parses into the expected declarations, kinds, scopes, and access.
- [ ] A fixture with two packages in a `:core` module and references to both from an `:app` module resolves each reference to `:core`, with no unresolved-import warnings.
- [ ] Changes are classified as for the other languages; a nullability change (`String` -> `String?`) is a signature change.
- [ ] Other languages' fixture results are unchanged.

## Constraints
Follow the TypeScript implementation in Sources/ReviewMapCore/TypeScript/ and its tests as the pattern. Java files are not parsed.
