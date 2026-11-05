---
# rm-mfpz
title: Parse Kotlin declarations and references
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:00:00Z
parent: rm-aks4
---

Add tree-sitter-kotlin and a `KotlinLanguage` with its extractor.

## Implementation scope
- Add tree-sitter-grammars/tree-sitter-kotlin (v1.1.0 has a Package.swift exposing `TreeSitterKotlin`) with an exact version. Check that its ABI loads with tree-sitter 0.25.10 and that it parses current Kotlin (context parameters, value classes, multi-dollar strings) well enough; fwcd/tree-sitter-kotlin is the fallback.
- Sources/ReviewMapCore/Kotlin/: `KotlinLanguage` (id `kotlin`, `.kt` and `.kts` files except Gradle scripts; `build/generated/**` is generated) and `KotlinExtractor`.
- Declarations: classes (data, sealed, enum, value, annotation, inner), interfaces (protocol), objects and companion objects, functions including extension functions (scoped to their receiver type), properties, enum entries (`case`), and type aliases. Visibility defaults to public. Record `suspend`, `inline`, `open`, `abstract`, `override`, `data`, `sealed`, `lateinit`, and `const` as modifiers, and annotations as attributes. Supertype lists go to `inherited`.
- References: imports (single, star, aliased) and names from the same package, which need no import. `NameRef.module` is the imported package.

## Acceptance criteria
- [ ] A Kotlin fixture pair under Tests/ReviewMapCoreTests/Fixtures/kotlin parses into the expected declarations, kinds, scopes, and access.
- [ ] Changes are classified as for the other languages; a nullability change (`String` -> `String?`) is a signature change.
- [ ] Other languages' fixture results are unchanged.

## Constraints
Follow the TypeScript implementation in Sources/ReviewMapCore/TypeScript/ and its tests as the pattern. Java files are not parsed.
