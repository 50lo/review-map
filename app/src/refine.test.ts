import { describe, expect, it } from "vitest";
import { buildIndex, carryFocus, collapse, defaultCollapsed, revealFocus, sameComponents, visible } from "./graph";
import { layout } from "./layout";
import { validate } from "./load";

// The app replaces the report on screen as the analysis refines it. Review item ids stay; component ids
// don't: the Bazel packages of the first view become the targets that own their files.
const item = (component: string) => ({
  id: "Sources/Feed/Feed.swift::Feed.limit()",
  component,
  kind: "func",
  qualifiedName: "Feed.limit()",
  change: "added",
  changes: ["added"],
  contractFlags: [],
  tags: [],
  usedBy: [],
  dependsOn: [],
  signature: {},
  location: { file: "Sources/Feed/Feed.swift", startLine: 25, endLine: 27, side: "head" },
});
const component = (id: string, kind: string, path: string) => ({ id, name: id, kind, isTest: false, paths: [path], changedReviewItems: 1, interfaceChanges: 0, changeScore: 0.5 });
const edge = (from: string, to: string) => ({ from, to, status: "changed", symbolsAdded: [], symbolsRemoved: [], refs: [], refCount: 1 });
const region = (id: string) => ({ id, reviewItem: "Sources/Feed/Feed.swift::Feed.limit()", kind: "review", file: "Sources/Feed/Feed.swift", startLine: 25, endLine: 27, side: "head", risk: 0.1, reasons: [] });

const preliminary = buildIndex(
  validate({
    components: [component("pkg:Sources/Feed", "bazelPackage", "Sources/Feed"), component("pkg:Sources/Storage", "bazelPackage", "Sources/Storage")],
    edges: [edge("pkg:Sources/Feed", "pkg:Sources/Storage")],
    reviewItems: [item("pkg:Sources/Feed")],
    regions: [region("Sources/Feed/Feed.swift::Feed.limit()/r1"), region("Sources/Feed/Feed.swift::Feed.limit()/c9")],
  }),
);
const refined = buildIndex(
  validate({
    components: [
      component("//Sources/Feed:Feed", "bazelTarget", "Sources/Feed"),
      component("//Sources/Storage:Storage", "bazelTarget", "Sources/Storage"),
      component("//Sources/Cache:Cache", "bazelTarget", "Sources/Cache"),
    ],
    edges: [edge("//Sources/Feed:Feed", "//Sources/Storage:Storage")],
    reviewItems: [item("//Sources/Feed:Feed")],
    regions: [region("Sources/Feed/Feed.swift::Feed.limit()/r1")],
  }),
);

describe("a refined report replacing the one on screen", () => {
  it("moves a component focus to the component that holds its code now", () => {
    // By its review items.
    expect(carryFocus(preliminary, refined, { type: "component", id: "pkg:Sources/Feed" })).toEqual({ type: "component", id: "//Sources/Feed:Feed" });
    // By its paths, when none of its review items is in the report.
    expect(carryFocus(preliminary, refined, { type: "interface", id: "pkg:Sources/Storage" })).toEqual({ type: "interface", id: "//Sources/Storage:Storage" });
    expect(carryFocus(preliminary, refined, { type: "component", id: "pkg:Gone" })).toBeNull();
  });

  it("keeps a review item focus, without a region that is gone", () => {
    const id = "Sources/Feed/Feed.swift::Feed.limit()";
    const kept = { type: "reviewItem" as const, id, region: `${id}/r1` };
    expect(carryFocus(preliminary, refined, kept)).toBe(kept);
    expect(carryFocus(preliminary, refined, { type: "reviewItem", id, region: `${id}/c9` })).toEqual({ type: "reviewItem", id });
    expect(carryFocus(preliminary, refined, { type: "reviewItem", id: "Other.swift::gone()" })).toBeNull();
  });

  it("moves an edge focus with its ends, and drops it when the dependency is gone", () => {
    expect(carryFocus(preliminary, refined, { type: "edge", key: "pkg:Sources/Feed->pkg:Sources/Storage" })).toEqual({
      type: "edge",
      key: "//Sources/Feed:Feed->//Sources/Storage:Storage",
    });
    expect(carryFocus(refined, preliminary, { type: "edge", key: "//Sources/Feed:Feed->//Sources/Cache:Cache" })).toBeNull();
    expect(carryFocus(preliminary, refined, { type: "bundle", from: "pkg:Sources/Feed", to: "pkg:Sources/Storage" })).toBeNull();
  });

  it("leaves a focus alone when the report still has what it names", () => {
    const focus = { type: "component" as const, id: "//Sources/Feed:Feed" };
    expect(carryFocus(refined, refined, focus)).toBe(focus);
    expect(carryFocus(preliminary, refined, null)).toBeNull();
    const location = { type: "location" as const, side: "head" as const, file: "Sources/Feed/Feed.swift", line: 3 };
    expect(carryFocus(preliminary, refined, location)).toBe(location);
  });

  it("tells whether the components are the same", () => {
    expect(sameComponents(refined, refined)).toBe(true);
    expect(sameComponents(preliminary, refined)).toBe(false);
  });

  it("draws the refined map from its own components", async () => {
    // What the viewer does when the report is replaced: the map state starts over from the new components.
    const opts = { scope: "all" as const, showTests: true };
    const focus = carryFocus(preliminary, refined, { type: "component", id: "pkg:Sources/Feed" });
    const vis = visible(refined, opts);
    const graph = collapse(refined, vis, revealFocus(refined, defaultCollapsed(refined, vis), focus));
    expect([...graph.nodes].sort()).toEqual(["//Sources/Cache:Cache", "//Sources/Feed:Feed", "//Sources/Storage:Storage"]);
    const placed = await layout(refined, graph.nodes, graph.edges);
    expect([...placed.keys()].every((id) => refined.components.has(id))).toBe(true);
  });
});
