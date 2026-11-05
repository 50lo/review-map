---
# rm-lnvs
title: Parse Rust declarations and references
status: todo
type: task
priority: normal
created_at: 2026-11-05T08:00:00Z
updated_at: 2026-11-05T08:50:00Z
parent: rm-wa33
---

Add tree-sitter-rust and a `RustLanguage` with its extractor.

## Implementation scope
- Add tree-sitter-rust (v0.24.2 has a Package.swift exposing `TreeSitterRust`) with an exact version.
- Sources/ReviewMapCore/Rust/: `RustLanguage` (id `rust`, `.rs` files; build-script output under `target/` and `OUT_DIR` includes are generated) and `RustExtractor`.
- Declarations: structs, enums (variants as `case`), unions, traits (protocol) and their items as requirements, `impl` blocks as extensions (an `impl Trait for Type` records `Trait` in `inherited`), functions, constants, statics, type aliases, and `macro_rules!`. Inline `mod` blocks scope their contents. `pub`, `pub(crate)`, and `pub(super)` map to access levels. Public API (rm-n95m's hook) is a `pub` item whose enclosing items and inline modules are also `pub`; file module privacy is not traced. Record `async`, `unsafe`, and `const fn` as modifiers and derives and attributes as attributes.
- References: `use` trees (`crate::`, `super::`, `self::`, external crates, globs, renames) resolved to a file through the module tree (`mod foo;` -> `foo.rs` or `foo/mod.rs`, and `#[path]`), plus qualified paths in code. `NameRef.source` and `NameRef.module` are filled as for TypeScript.

## Acceptance criteria
- [ ] A Rust fixture pair under Tests/ReviewMapCoreTests/Fixtures/rust parses into the expected declarations, kinds, scopes, and access.
- [ ] Changes are classified as for the other languages.
- [ ] Other languages' fixture results are unchanged.

## Constraints
Follow the TypeScript implementation in Sources/ReviewMapCore/TypeScript/ and its tests as the pattern.
