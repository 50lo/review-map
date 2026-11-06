import { describe, expect, it } from "vitest";
import { LANGUAGES, languageOfPath } from "./languages";
import { highlightFile, languageOf } from "./highlight";
import { kindLabel } from "./graph";
import { validate } from "./load";

describe("viewer language table", () => {
  for (const language of LANGUAGES) {
    for (const [extension, highlighting] of Object.entries(language.extensions)) {
      it(`recognizes and highlights ${language.name} .${extension} files`, async () => {
        const file = `src/example.${extension}`;
        expect(languageOfPath(file)).toBe(language.id);
        expect(languageOf(file)).toBe(highlighting.language);
        // Exercise grammar registration too: a missing grammar silently falls back to plain text.
        const tokens = await highlightFile(`table:${extension}`, file, "let value = 1");
        expect(tokens.flat().some((token) => token.light && token.dark)).toBe(true);
        expect(tokens[0].map((token) => token.text).join("")).toBe("let value = 1");
      });
    }
  }

  it.each([
    ["App.xcodeproj", "swift"], ["ios/App.xcodeproj/project.pbxproj", "swift"],
    ["Package.swift", "swift"], ["ios/Package.resolved", "swift"],
    ["package.json", "typescript"], ["viewer/package-lock.json", "typescript"],
    ["tsconfig.json", "typescript"], ["viewer/tsconfig.base.json", "typescript"],
    ["pnpm-lock.yaml", "typescript"], ["yarn.lock", "typescript"],
    ["bun.lock", "typescript"], ["bun.lockb", "typescript"],
    ["Cargo.toml", "rust"], ["crates/core/Cargo.lock", "rust"], ["not-Cargo.toml", undefined],
    ["go.mod", "go"], ["tools/go.sum", "go"], ["go.work", "go"],
    ["not-package.json", undefined], ["not-tsconfig.json", undefined],
    ["src/file.js", undefined], ["src/file.TS", undefined], ["README.md", undefined],
  ])("keeps ecosystem detection for %s", (file, expected) => {
    expect(languageOfPath(file)).toBe(expected);
    // Manifests indicate an ecosystem but are not source code to highlight.
    if (!file.endsWith(".swift")) expect(languageOf(file)).toBeUndefined();
  });

  it("keeps language kind names and TypeScript's property/variable distinction", () => {
    const reviewItem = validate({ components: [], edges: [], reviewItems: [{ kind: "protocol", location: { file: "src/api.ts" } }] }).reviewItems[0];
    expect(kindLabel(reviewItem)).toBe("interface");
    expect(kindLabel({ ...reviewItem, kind: "var", qualifiedName: "value" })).toBe("variable");
    expect(kindLabel({ ...reviewItem, kind: "var", qualifiedName: "Store.value" })).toBe("property");
    expect(kindLabel({ ...reviewItem, location: { ...reviewItem.location, file: "src/api.swift" } })).toBe("protocol");
    expect(kindLabel({ ...reviewItem, location: { ...reviewItem.location, file: "src/api.unknown" } })).toBe("protocol");
  });

  it("names Go kinds, telling methods from functions and fields from variables", () => {
    const reviewItem = validate({ components: [], edges: [], reviewItems: [{ kind: "func", qualifiedName: "New()", location: { file: "cart/cart.go" } }] }).reviewItems[0];
    expect(kindLabel(reviewItem)).toBe("function");
    expect(kindLabel({ ...reviewItem, qualifiedName: "Cart.Add()" })).toBe("method");
    expect(kindLabel({ ...reviewItem, kind: "var", qualifiedName: "Cart.Note" })).toBe("field");
    expect(kindLabel({ ...reviewItem, kind: "var", qualifiedName: "ErrEmpty" })).toBe("variable");
    expect(kindLabel({ ...reviewItem, kind: "protocol", qualifiedName: "Store" })).toBe("interface");
    expect(kindLabel({ ...reviewItem, kind: "typealias", qualifiedName: "ID" })).toBe("type");
  });

  it("names Rust declarations, including removed constants and statics", () => {
    const item = validate({ components: [], edges: [], reviewItems: [{ kind: "protocol", location: { file: "src/lib.rs" } }] }).reviewItems[0];
    for (const [kind, label] of Object.entries({ protocol: "trait", extension: "impl", case: "variant", func: "fn", typealias: "type", var: "field" })) {
      expect(kindLabel({ ...item, kind })).toBe(label);
    }
    expect(kindLabel({ ...item, kind: "var", signature: { head: "pub const LIMIT: usize = 10" } })).toBe("const");
    expect(kindLabel({ ...item, kind: "var", signature: { head: "pub static mut COUNT: usize = 0" } })).toBe("static");
    expect(kindLabel({ ...item, kind: "var", signature: { base: "const LIMIT: usize = 10" } })).toBe("const");
    expect(kindLabel({ ...item, kind: "var", signature: { head: "value: &'static str" } })).toBe("field");
  });

});
