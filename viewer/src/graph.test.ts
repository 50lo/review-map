import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { buildIndex, componentEntities, edgeKey, flagLabel, related, startHere, visible } from "./graph";
import { layout } from "./layout";
import { validate } from "./load";

// The analyzer's own snapshot, so the viewer is tested against what the analyzer really writes.
const fixture = path.resolve(__dirname, "../../Tests/ReviewMapCoreTests/Fixtures/basic/expected.json");
const model = validate(JSON.parse(fs.readFileSync(fixture, "utf8")));
const index = buildIndex(model);

describe("visible", () => {
  it("shows changed components and the ends of changed edges, without tests", () => {
    const v = visible(index, { scope: "changed", showTests: false });
    expect(v.nodes.has("ext:swift-collections")).toBe(true); // version bumped
    expect(v.hiddenTests).toBe(1);
    // FeaturesTests has no changes and only unchanged edges, so it is a neighbor, not a change.
    expect(visible(index, { scope: "changed", showTests: true }).nodes.has("spm:FeaturesTests")).toBe(false);
    expect(visible(index, { scope: "neighbors", showTests: true }).nodes.has("spm:FeaturesTests")).toBe(true);
  });

  it("adds unchanged neighbors on request", () => {
    const v = visible(index, { scope: "neighbors", showTests: false });
    expect([...v.nodes].sort()).toEqual([
      "cfg:Core",
      "ext:swift-collections",
      "folder:App",
      "spm:Features",
      "spm:Features/Catalog",
      "spm:Features/Checkout",
      "spm:Networking",
      "spm:Persistence",
    ]);
    expect(v.hiddenTests).toBe(1);
    expect(v.edges.every((e) => v.nodes.has(e.from) && v.nodes.has(e.to))).toBe(true);
  });

  it("adds tests and the whole system on request", () => {
    const v = visible(index, { scope: "all", showTests: true });
    expect(v.nodes.size).toBe(model.components.length);
    expect(v.edges.length).toBe(model.edges.length);
    expect(v.hiddenTests + v.hiddenUnrelated).toBe(0);
  });

  it("keeps a split folder's target as its group", () => {
    const tiny = buildIndex({
      ...model,
      components: model.components.map((c) => (c.id === "spm:Features" ? { ...c, changedEntities: 0 } : c)),
    });
    expect(visible(tiny, { scope: "changed", showTests: false }).nodes.has("spm:Features")).toBe(true);
  });
});

describe("related", () => {
  it("lights the focus, its edges, their ends, and the group around them", () => {
    const v = visible(index, { scope: "changed", showTests: false });
    const r = related(index, v.edges, { type: "component", id: "spm:Networking" })!;
    expect(r.nodes.has("spm:Features/Checkout")).toBe(true);
    expect(r.nodes.has("spm:Features")).toBe(true);
    expect(r.nodes.has("ext:swift-collections")).toBe(true);
    expect(r.nodes.has("spm:Persistence")).toBe(false);
    expect(r.edges.has("spm:Features/Checkout->spm:Networking")).toBe(true);
    expect(related(index, v.edges, null)).toBeNull();
  });
});

describe("startHere", () => {
  const items = startHere(index);

  it("falls back to contract flags when there are no regions", () => {
    expect(model.regions.length).toBe(0);
    expect(items.length).toBe(10);
    expect(items.every((i) => i.source === "flags")).toBe(true);
  });

  it("leaves out cosmetic changes and folds members into their parent", () => {
    const names = items.map((i) => i.entity.qualifiedName);
    expect(names).not.toContain("CatalogView.title()");
    expect(names).toContain("Item");
    expect(names).not.toContain("Item.price");
    const item = items.find((i) => i.entity.qualifiedName === "Item")!;
    expect(item.members.map((m) => m.qualifiedName)).toContain("Item.currency");
    expect(item.reasons).toContain("codable-shape");
  });

  it("ranks interface contract changes above plain body changes", () => {
    const rank = (n: string) => items.findIndex((i) => i.entity.qualifiedName === n);
    expect(rank("CartRepository")).toBeGreaterThanOrEqual(0);
    expect(rank("CartRepository")).toBeLessThan(5);
  });

  it("uses regions when the analyzer provides them", () => {
    const e = model.entities[0];
    const withRegions = buildIndex({
      ...model,
      regions: [
        { id: "r1", entity: e.id, kind: "review", file: "a", startLine: 1, endLine: 2, side: "head", risk: 0.2, reasons: ["low"] },
        { id: "r2", entity: e.id, kind: "review", file: "a", startLine: 3, endLine: 4, side: "head", risk: 0.9, reasons: ["high"] },
        { id: "r3", entity: e.id, kind: "context", file: "a", startLine: 5, endLine: 6, side: "head", risk: 1, reasons: [] },
      ],
    });
    expect(startHere(withRegions).map((i) => i.id)).toEqual(["r2", "r1"]);
  });
});

describe("componentEntities", () => {
  it("counts cosmetic changes instead of listing them", () => {
    const r = componentEntities(index, "spm:Features/Catalog");
    expect(r.cosmetic).toBe(1);
    expect(r.shown.map((e) => e.change)).not.toContain("cosmetic");
  });
});

describe("layout", () => {
  it("places every visible node, with split folders inside their target", async () => {
    const v = visible(index, { scope: "changed", showTests: false });
    const placed = await layout(index, v.nodes, v.edges);
    expect(placed.size).toBe(v.nodes.size);
    expect(placed.get("spm:Features")!.isGroup).toBe(true);
    expect(placed.get("spm:Features/Checkout")!.parent).toBe("spm:Features");
    const group = placed.get("spm:Features")!;
    const child = placed.get("spm:Features/Checkout")!;
    expect(child.x + child.width).toBeLessThanOrEqual(group.width);
  });
});

describe("misc", () => {
  it("formats flags", () => {
    expect(flagLabel("async-added")).toBe("async added");
    expect(flagLabel("access-changed:internal->public")).toBe("access changed: internal → public");
  });
  it("edge keys are stable", () => {
    expect(edgeKey({ from: "a", to: "b" })).toBe("a->b");
  });
  it("tolerates unknown and missing fields", () => {
    const m = validate({ components: [], edges: [], somethingNew: 1 });
    expect(m.entities).toEqual([]);
  });
});
