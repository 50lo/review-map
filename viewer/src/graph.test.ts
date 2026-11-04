import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import {
  buildIndex,
  bundleKey,
  bundleMembers,
  collapse,
  componentEntities,
  contextOf,
  defaultCollapsed,
  edgeKey,
  flagLabel,
  hiddenNeighbors,
  llmOf,
  regionPosition,
  related,
  removalCandidates,
  revealFocus,
  rollup,
  startHere,
  stepRegion,
  visible,
} from "./graph";
import { editorFrom, openInEditor } from "../server/repo";
import { focusToHash, hashToFocus } from "./nav";
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

describe("neighbors on request", () => {
  it("adds the neighbors of expanded components, whatever the scope", () => {
    const base = visible(index, { scope: "changed", showTests: true });
    const hidden = hiddenNeighbors(index, base, "spm:Features/Checkout", true);
    expect(hidden).toContain("spm:FeaturesTests");
    const more = visible(index, { scope: "changed", showTests: true }, new Set(["spm:Features/Checkout"]));
    for (const id of hidden) expect(more.nodes.has(id)).toBe(true);
    expect(hiddenNeighbors(index, more, "spm:Features/Checkout", true)).toEqual([]);
    // The test filter still applies.
    expect(hiddenNeighbors(index, base, "spm:Features/Checkout", false)).not.toContain("spm:FeaturesTests");
  });
});

describe("collapsed groups", () => {
  const v = visible(index, { scope: "changed", showTests: false });

  it("draws a collapsed group as one node and bundles the edges of its folders", () => {
    const g = collapse(index, v, new Set(["spm:Features"]));
    expect(g.nodes.has("spm:Features")).toBe(true);
    expect(g.nodes.has("spm:Features/Checkout")).toBe(false);
    expect(g.collapsed.get("spm:Features")).toBe(2);
    const b = g.edges.find((e) => e.from === "spm:Features" && e.to === "spm:Networking")!;
    expect(b.bundle).toBe(true);
    expect(b.key).toBe(bundleKey("spm:Features", "spm:Networking"));
    expect(b.members.map(edgeKey)).toContain("spm:Features/Checkout->spm:Networking");
    expect(b.refCount).toBe(b.members.reduce((n, e) => n + (e.refCount ?? e.refs.length), 0));
    // No edge inside the group, and every edge's ends are drawn.
    expect(g.edges.every((e) => e.from !== e.to && g.nodes.has(e.from) && g.nodes.has(e.to))).toBe(true);
    expect(bundleMembers(index, "spm:Features", "spm:Networking").map(edgeKey)).toEqual(b.members.map(edgeKey));
  });

  it("keeps model edges as they are when nothing is collapsed", () => {
    const g = collapse(index, v, new Set());
    expect(g.nodes).toEqual(v.nodes);
    expect(g.edges.map((e) => e.key).sort()).toEqual(v.edges.map(edgeKey).sort());
    expect(g.edges.every((e) => !e.bundle)).toBe(true);
  });

  it("merges statuses: the same one, or changed when they differ", () => {
    const g = collapse(index, v, new Set(["spm:Features"]));
    for (const e of g.edges) {
      const statuses = new Set(e.members.map((m) => m.status));
      expect(e.status).toBe(statuses.size === 1 ? e.members[0].status : "changed");
    }
  });

  it("rolls up change counts over the group", () => {
    const r = rollup(index, "spm:Features");
    const inside = model.components.filter((c) => c.id === "spm:Features" || c.parent === "spm:Features");
    expect(r.changedEntities).toBe(inside.reduce((n, c) => n + c.changedEntities, 0));
    expect(r.changed).toBe(true);
  });

  it("starts collapsed only on a large map, and opens the group around the focus", () => {
    expect(defaultCollapsed(index, v).size).toBe(0);
    const big = { ...v, nodes: new Set([...v.nodes, ...Array.from({ length: 50 }, (_, i) => `x${i}`)]) };
    expect([...defaultCollapsed(index, big)]).toEqual(["spm:Features"]);
    const c = new Set(["spm:Features"]);
    expect(revealFocus(index, c, { type: "component", id: "spm:Networking" })).toBe(c);
    expect(revealFocus(index, c, { type: "component", id: "spm:Features/Checkout" }).size).toBe(0);
    expect(revealFocus(index, c, { type: "edge", key: "spm:Features/Checkout->spm:Networking" }).size).toBe(0);
    // The group's own edge would be drawn inside a bundle, so it opens too; selecting the group doesn't.
    expect(revealFocus(index, c, { type: "edge", key: "spm:Features->spm:Networking" }).size).toBe(0);
    expect(revealFocus(index, c, { type: "component", id: "spm:Features" })).toBe(c);
    const entity = model.entities.find((e) => e.component === "spm:Features/Checkout")!;
    expect(revealFocus(index, c, { type: "entity", id: entity.id }).size).toBe(0);
  });

  it("lights a selected bundle and its ends", () => {
    const g = collapse(index, v, new Set(["spm:Features"]));
    const r = related(index, g.edges, { type: "bundle", from: "spm:Features", to: "spm:Networking" })!;
    expect(r.edges.has(bundleKey("spm:Features", "spm:Networking"))).toBe(true);
    expect(r.nodes.has("spm:Networking")).toBe(true);
  });

  it("keeps a bundle focus in the URL", () => {
    const f = { type: "bundle" as const, from: "spm:Features", to: "a b/c" };
    expect(hashToFocus("#" + focusToHash(f))).toEqual(f);
  });
});

describe("editor", () => {
  it("reads presets and commands, and defaults to Xcode on macOS", () => {
    expect(editorFrom(undefined, "darwin")?.name).toBe("Xcode");
    expect(editorFrom(undefined, "linux")).toBeNull();
    expect(editorFrom("vscode", "linux")?.args).toEqual(["code", "-g", "{file}:{line}"]);
    expect(editorFrom("Zed")?.name).toBe("Zed");
    expect(editorFrom("/usr/local/bin/subl {file}:{line}")).toEqual({ name: "subl", args: ["/usr/local/bin/subl", "{file}:{line}"] });
    expect(editorFrom("nano")).toBeNull();
  });

  it("runs the command on a file in the working copy, and nothing outside it", async () => {
    const repo = { root: path.resolve(__dirname, "../.."), baseSha: "", headSha: "" };
    const ok = { name: "Test", args: ["test", "-f", "{file}"] };
    expect(await openInEditor(ok, repo, "README.md", 3)).toEqual({ ok: true, message: "Opened in Test" });
    expect((await openInEditor(ok, repo, "../etc/passwd", 1)).ok).toBe(false);
    expect((await openInEditor(ok, repo, "missing.swift", 1)).ok).toBe(false);
    expect((await openInEditor({ name: "Bad", args: ["false"] }, repo, "README.md", 1)).ok).toBe(false);
  });
});

describe("related", () => {
  it("lights the focus, its edges, their ends, and the group around them", () => {
    const v = visible(index, { scope: "changed", showTests: false });
    const edges = collapse(index, v, new Set()).edges;
    const r = related(index, edges, { type: "component", id: "spm:Networking" })!;
    expect(r.nodes.has("spm:Features/Checkout")).toBe(true);
    expect(r.nodes.has("spm:Features")).toBe(true);
    expect(r.nodes.has("ext:swift-collections")).toBe(true);
    expect(r.nodes.has("spm:Persistence")).toBe(false);
    expect(r.edges.has("spm:Features/Checkout->spm:Networking")).toBe(true);
    expect(related(index, edges, null)).toBeNull();
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

describe("LLM ranking", () => {
  const annotatedPath = path.resolve(__dirname, "../../Tests/ReviewMapCoreTests/Fixtures/basic/annotated.json");
  const annotated = validate(JSON.parse(fs.readFileSync(annotatedPath, "utf8")));
  const on = buildIndex(annotated);
  const off = buildIndex(annotated, { llm: false });

  it("is on by default when the model has annotations, and never without them", () => {
    expect(on.hasLLM && on.llm).toBe(true);
    expect(off.hasLLM && !off.llm).toBe(true);
    expect(index.hasLLM || index.llm).toBe(false);
    expect(buildIndex(model, { llm: true }).llm).toBe(false);
  });

  it("orders regions by LLM risk when on, and by deterministic risk when off", () => {
    const llmRisks = on.riskOrder.map((r) => r.llm?.risk ?? r.risk);
    expect(llmRisks).toEqual([...llmRisks].sort((a, b) => b - a));
    expect(off.riskOrder.map((r) => r.id)).toEqual(index.riskOrder.map((r) => r.id));
    expect(on.riskOrder.map((r) => r.id)).not.toEqual(off.riskOrder.map((r) => r.id));
    expect(new Set(on.riskOrder.map((r) => r.id))).toEqual(new Set(off.riskOrder.map((r) => r.id)));
  });

  it("scores Start here by LLM risk only when on", () => {
    const top = startHere(on)[0];
    const r = on.regions.get(top.id)!;
    expect(top.score).toBe(r.llm?.risk ?? r.risk);
    for (const it of startHere(off, 100)) expect(it.score).toBe(off.regions.get(it.id)!.risk);
  });

  it("prunes and ranks context only when on", () => {
    const entity = [...on.contextByEntity.keys()].find((id) => contextOf(on, id).pruned.length > 0)!;
    expect(entity).toBeDefined();
    const { shown, pruned } = contextOf(on, entity);
    expect(pruned.every((c) => c.llm?.keep === false)).toBe(true);
    expect(shown.map((c) => c.llm?.rank)).toEqual(shown.map((_, i) => i + 1));
    expect(contextOf(off, entity)).toEqual({ shown: off.contextByEntity.get(entity), pruned: [] });
  });

  it("lists removal candidates only when on", () => {
    expect(removalCandidates(on).length).toBeGreaterThan(0);
    expect(removalCandidates(on).every((r) => r.llm?.removal)).toBe(true);
    expect(removalCandidates(off)).toEqual([]);
  });

  it("hides summaries when off", () => {
    const e = annotated.entities.find((x) => x.llm)!;
    expect(llmOf(on, e)?.summary).toBeTruthy();
    expect(llmOf(off, e)).toBeUndefined();
  });
});
