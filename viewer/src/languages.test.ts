import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { componentLanguages } from "./languages";
import { validate } from "./load";
import type { Component } from "./types";

const component = (id: string, kind = "folder", parent?: string): Component => ({
  id, name: id, kind, parent, paths: [], changedEntities: 0, interfaceChanges: 0, changeScore: 0,
});

describe("componentLanguages", () => {
  it.each([
    ["basic", "spm:Features", "ext:swift-collections", "swift"],
    ["typescript", "npm:@shop/web", "ext:react", "typescript"],
    ["go", "go:example.com/shop/report", "ext:golang.org/x/text", "go"],
  ])("reads first- and third-party ecosystems from the analyzer's %s model", (fixture, first, external, language) => {
    const model = validate(JSON.parse(fs.readFileSync(path.resolve(__dirname, `../../Tests/ReviewMapCoreTests/Fixtures/${fixture}/expected.json`), "utf8")));
    const languages = componentLanguages(model);
    expect(languages.get(first)).toEqual([language]);
    expect(languages.get(external)).toEqual([language]);
  });

  it("uses all retained references, including removed edges, without changing the callee's language", () => {
    const model = validate({
      components: [component("swift", "spmTarget"), component("ts", "npmPackage"), component("ext", "external")],
      edges: [
        { from: "swift", to: "ext", status: "removed", refs: [{ file: "Package.swift" }] },
        { from: "ts", to: "ext", status: "unchanged", refs: [{ file: "viewer/package.json" }] },
        { from: "ts", to: "swift", status: "unchanged", refs: [{ file: "viewer/main.tsx" }] },
      ],
    });
    const languages = componentLanguages(model);
    expect(languages.get("ext")).toEqual(["swift", "typescript"]);
    expect(languages.get("swift")).toEqual(["swift"]);
    expect(languages.get("ts")).toEqual(["typescript"]);
  });

  it("inherits split targets, rolls mixed groups up, and leaves unknown packages unmarked", () => {
    const model = validate({
      components: [
        component("target", "spmTarget"), component("split", "folder", "target"),
        component("group"), { ...component("child", "folder", "group"), paths: ["src/file.mts", "src/file.swift"] },
        component("ext:swift-sounding-name", "external"),
        component("cycle-a", "folder", "cycle-b"), component("cycle-b", "folder", "cycle-a"),
      ],
      edges: [],
    });
    const languages = componentLanguages(model);
    expect(languages.get("split")).toEqual(["swift"]);
    expect(languages.get("group")).toEqual(["swift", "typescript"]);
    expect(languages.get("ext:swift-sounding-name")).toEqual([]);
    expect(languages.get("cycle-a")).toEqual([]);
  });
});
