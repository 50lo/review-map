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
    ["go.mod", "go"], ["tools/go.sum", "go"], ["go.work", "go"],
    ["not-package.json", undefined], ["not-tsconfig.json", undefined],
    ["src/file.js", undefined], ["src/file.TS", undefined], ["README.md", undefined],
  ])("keeps ecosystem detection for %s", (file, expected) => {
    expect(languageOfPath(file)).toBe(expected);
    // Manifests indicate an ecosystem but are not source code to highlight.
    if (!file.endsWith(".swift")) expect(languageOf(file)).toBeUndefined();
  });

  it("keeps language kind names and TypeScript's property/variable distinction", () => {
    const entity = validate({ components: [], edges: [], entities: [{ kind: "protocol", location: { file: "src/api.ts" } }] }).entities[0];
    expect(kindLabel(entity)).toBe("interface");
    expect(kindLabel({ ...entity, kind: "var", qualifiedName: "value" })).toBe("variable");
    expect(kindLabel({ ...entity, kind: "var", qualifiedName: "Store.value" })).toBe("property");
    expect(kindLabel({ ...entity, location: { ...entity.location, file: "src/api.swift" } })).toBe("protocol");
    expect(kindLabel({ ...entity, location: { ...entity.location, file: "src/api.unknown" } })).toBe("protocol");
  });

  it("names Go kinds, telling methods from functions and fields from variables", () => {
    const entity = validate({ components: [], edges: [], entities: [{ kind: "func", qualifiedName: "New()", location: { file: "cart/cart.go" } }] }).entities[0];
    expect(kindLabel(entity)).toBe("function");
    expect(kindLabel({ ...entity, qualifiedName: "Cart.Add()" })).toBe("method");
    expect(kindLabel({ ...entity, kind: "var", qualifiedName: "Cart.Note" })).toBe("field");
    expect(kindLabel({ ...entity, kind: "var", qualifiedName: "ErrEmpty" })).toBe("variable");
    expect(kindLabel({ ...entity, kind: "protocol", qualifiedName: "Store" })).toBe("interface");
    expect(kindLabel({ ...entity, kind: "typealias", qualifiedName: "ID" })).toBe("type");
  });
});
