import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { buildIndex, componentEntities, edgeKey, flagLabel, regionPosition, related, startHere, stepRegion, visible } from "./graph";
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
  const flagsOnly = buildIndex({ ...model, regions: [] });

  it("ranks by regions when the analyzer scores them", () => {
    expect(index.hasRegions).toBe(true);
    expect(items.length).toBe(10);
    expect(items.every((i) => i.source === "regions")).toBe(true);
    for (let i = 1; i < items.length; i++) expect(items[i - 1].score).toBeGreaterThanOrEqual(items[i].score);
  });

  it("leads each item to its riskiest region", () => {
    const add = items.find((i) => i.entity.qualifiedName === "Cart.add(_:)")!;
    expect(add.focus).toEqual({ type: "entity", id: add.entity.id, region: `${add.entity.id}/r1` });
    expect(add.reasons.some((r) => r.includes("guard removed"))).toBe(true);
  });

  it("ranks a removed guard above a new force unwrap", () => {
    const all = startHere(index, 100);
    const rank = (n: string) => all.findIndex((i) => i.entity.qualifiedName === n);
    expect(rank("Cart.add(_:)")).toBeGreaterThanOrEqual(0);
    expect(rank("Cart.add(_:)")).toBeLessThan(rank("Cart.first()"));
  });

  it("leaves out cosmetic and test changes and folds members into their parent", () => {
    const all = startHere(index, 100);
    const names = all.map((i) => i.entity.qualifiedName);
    expect(names).not.toContain("CatalogView.title()");
    expect(names).not.toContain("CheckoutTests.testTotal()");
    expect(names).toContain("Item");
    expect(names).not.toContain("Item.price");
    const item = all.find((i) => i.entity.qualifiedName === "Item")!;
    expect(item.members.map((m) => m.qualifiedName)).toContain("Item.currency");
    expect(item.reasons).toContain("codable-shape");
  });

  it("falls back to contract flags without regions", () => {
    const flagItems = startHere(flagsOnly);
    expect(flagItems.every((i) => i.source === "flags")).toBe(true);
    const rank = (n: string) => flagItems.findIndex((i) => i.entity.qualifiedName === n);
    expect(rank("CartRepository")).toBeGreaterThanOrEqual(0);
    expect(rank("CartRepository")).toBeLessThan(5);
  });

  it("groups an entity's regions into one item scored by the riskiest", () => {
    const e = model.entities[0];
    const withRegions = buildIndex({
      ...model,
      regions: [
        { id: "r1", entity: e.id, kind: "review", file: "a", startLine: 1, endLine: 2, side: "head", risk: 0.2, reasons: ["low"] },
        { id: "r2", entity: e.id, kind: "review", file: "a", startLine: 3, endLine: 4, side: "head", risk: 0.9, reasons: ["high"] },
        { id: "r3", entity: e.id, kind: "context", file: "a", startLine: 5, endLine: 6, side: "head", risk: 1, reasons: [] },
      ],
    });
    const got = startHere(withRegions);
    expect(got.map((i) => [i.id, i.score, i.regionCount])).toEqual([["r2", 0.9, 2]]);
    expect(got[0].reasons).toEqual(["high", "low"]);
  });
});

describe("region stepping", () => {
  const order = index.riskOrder;

  it("orders review and removed regions by risk, without context or test code", () => {
    expect(order.length).toBeGreaterThan(5);
    expect(order.every((r) => r.kind !== "context")).toBe(true);
    expect(order.some((r) => r.entity.includes("CheckoutTests"))).toBe(false);
    for (let i = 1; i < order.length; i++) expect(order[i - 1].risk).toBeGreaterThanOrEqual(order[i].risk);
  });

  it("steps forward and back from anywhere", () => {
    const first = stepRegion(index, null, 1);
    expect(first).toEqual({ type: "entity", id: order[0].entity, region: order[0].id });
    expect(regionPosition(index, first)).toBe(1);
    const second = stepRegion(index, first, 1);
    expect(regionPosition(index, second)).toBe(2);
    expect(stepRegion(index, second, -1)).toEqual(first);
    expect(stepRegion(index, first, -1)).toEqual(first);
    expect(regionPosition(index, stepRegion(index, null, -1))).toBe(order.length);
  });

  it("enters an entity's riskiest region first", () => {
    const r = order[3];
    expect(stepRegion(index, { type: "entity", id: r.entity }, 1)).toEqual({ type: "entity", id: r.entity, region: order.find((x) => x.entity === r.entity)!.id });
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
