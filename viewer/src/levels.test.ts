import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { foldRows, lineChanges, signatureSegments } from "./diff";
import { buildIndex } from "./graph";
import { dependsOnTarget, interfaceModel, lastName, neighbors, reviewOrder, symbolTargets, usedByTarget } from "./levels";
import { validate } from "./load";
import { focusToHash, hashToFocus, levelOf, type Focus } from "./nav";
import { notesMarkdown } from "./review";

const fixture = path.resolve(__dirname, "../../Tests/ReviewMapCoreTests/Fixtures/basic/expected.json");
const report = validate(JSON.parse(fs.readFileSync(fixture, "utf8")));
const index = buildIndex(report);

describe("signatureSegments", () => {
  it("marks only the tokens that differ from base", () => {
    const segs = signatureSegments("func total() -> Int", "func total() -> Decimal");
    expect(segs.filter((s) => s.changed).map((s) => s.text)).toEqual(["Decimal"]);
    expect(segs.map((s) => s.text).join("")).toBe("func total() -> Decimal");
  });

  it("marks added effects and ignores spacing", () => {
    const segs = signatureSegments("func items() -> [Item]", "func items()  async throws -> [Item]");
    expect(segs.filter((s) => s.changed).map((s) => s.text.trim())).toEqual(["async throws"]);
  });

  it("returns one unchanged segment without a base", () => {
    expect(signatureSegments(undefined, "struct A")).toEqual([{ text: "struct A", changed: false }]);
  });
});

describe("lineChanges", () => {
  it("marks changed head lines and keeps removed lines where they were", () => {
    const base = ["func f() {", "  guard ok else { return }", "  a()", "  b()", "}"];
    const head = ["func f() {", "    a()", "  c()", "  b()", "}"];
    const r = lineChanges(base, head);
    expect(r.changed).toEqual([false, false, true, false, false]); // re-indented a() is not a change
    expect([...r.removed]).toEqual([[0, ["  guard ok else { return }"]]]);
  });

  it("puts lines removed at the end after the last head line", () => {
    const r = lineChanges(["a", "b", "c"], ["a"]);
    expect([...r.removed]).toEqual([[0, ["b", "c"]]]);
  });
});

describe("foldRows", () => {
  it("shows short code whole", () => {
    expect(foldRows(10, [5]).every((r) => r.kind === "line")).toBe(true);
  });

  it("folds long runs away from interesting lines", () => {
    const rows = foldRows(100, [0, 50], 3);
    expect(rows.filter((r) => r.kind === "fold")).toEqual([
      { kind: "fold", from: 4, to: 46 },
      { kind: "fold", from: 54, to: 99 },
    ]);
  });
});

describe("nav", () => {
  it("round-trips every focus through the hash", () => {
    const all: Focus[] = [
      null,
      { type: "component", id: "spm:Features/Checkout" },
      { type: "edge", key: "a->b" },
      { type: "interface", id: "cfg:Core" },
      { type: "reviewItem", id: "cfg:Core::Cart.price(for:)" },
      { type: "reviewItem", id: "cfg:Core::Cart.add(_:)", region: "cfg:Core::Cart.add(_:)/r1" },
      { type: "location", side: "head", file: "Sources/A b/C.swift", line: 12 },
    ];
    for (const f of all) expect(hashToFocus("#" + focusToHash(f))).toEqual(f);
    expect(all.map(levelOf)).toEqual([1, 1, 1, 2, 3, 3, 3]);
  });
});

describe("interface view", () => {
  it("lists interface changes by kind and internal changes below", () => {
    const m = interfaceModel(index, "cfg:Core");
    expect(m.groups.map((g) => g.title)).toEqual(["Protocols and interfaces", "Types", "Functions", "Properties", "Enum cases and members"].filter((t) => m.groups.some((g) => g.title === t)));
    expect(m.groups.find((g) => g.title === "Protocols and interfaces")?.reviewItems.map((e) => e.qualifiedName)).toContain("CartRepository");
    for (const g of m.groups) expect(g.reviewItems.every((e) => e.isInterface)).toBe(true);
    expect(m.internal.every((e) => !e.isInterface)).toBe(true);
  });

  it("steps through review items in the interface view's order", () => {
    const order = reviewOrder(index, "cfg:Core");
    const second = neighbors(index, order[1]);
    expect(second.prev?.id).toBe(order[0].id);
    expect(second.next?.id).toBe(order[2]?.id);
    expect(second.position).toBe(2);
    expect(neighbors(index, order[0]).prev).toBeUndefined();
  });
});

describe("references", () => {
  it("leads a caller to its changed review item, or else to the line", () => {
    const total = index.reviewItems.get("cfg:Core::Cart.total()")!;
    for (const u of total.usedBy ?? []) {
      const f = usedByTarget(index, u);
      if (f?.type === "reviewItem") expect(index.reviewItems.get(f.id)?.qualifiedName).toBe(u.symbol);
      else expect(f).toEqual({ type: "location", side: "head", file: u.file, line: u.line });
    }
  });

  it("leads a dependency to the changed declaration, or else to its component", () => {
    const store = report.reviewItems.find((e) => e.qualifiedName === "PriceCache.price(for:)")!;
    const dep = store.dependsOn![0];
    const f = dependsOnTarget(index, dep);
    expect(f?.type === "reviewItem" || (f?.type === "interface" && f.id === dep.component)).toBe(true);
  });

  it("makes changed type names clickable in code", () => {
    const t = symbolTargets(index);
    expect(t.get("CartRepository")).toEqual({ type: "reviewItem", id: "cfg:Core::CartRepository" });
  });

  it("splits the last name of a qualified name outside argument lists", () => {
    expect(lastName("Cart.price(for:)")).toBe("price(for:)");
    expect(lastName("A.B.f(x.y:)")).toBe("f(x.y:)");
    expect(lastName("Cart")).toBe("Cart");
  });
});

describe("review notes", () => {
  it("exports notes as Markdown in file order", () => {
    const md = notesMarkdown({
      b: { text: "Why drop the limit?", reviewItem: "x", label: "Cart.add(_:)", file: "Sources/Core/Cart.swift", startLine: 8, endLine: 8, side: "base" },
      a: { text: "Check callers", reviewItem: "y", label: "Item", file: "Sources/Core/Item.swift", startLine: 3, endLine: 5, side: "head" },
      c: { text: "first", reviewItem: "z", label: "Cart.first()", file: "Sources/Core/Cart.swift", startLine: 15, endLine: 17, side: "head" },
    });
    expect(md.split("\n").filter((l) => l.startsWith("**"))).toEqual([
      "**`Sources/Core/Cart.swift:8`** (removed code) · Cart.add(_:)",
      "**`Sources/Core/Cart.swift:15-17`** · Cart.first()",
      "**`Sources/Core/Item.swift:3-5`** · Item",
    ]);
    expect(notesMarkdown({})).toBe("");
  });
});

describe("context regions", () => {
  it("each supports a review or removed region of its review item", () => {
    for (const [reviewItem, cs] of index.contextByReviewItem) {
      const own = new Set((index.regionsByReviewItem.get(reviewItem) ?? []).map((r) => r.id));
      for (const c of cs) expect(c.supports?.every((id) => own.has(id))).toBe(true);
    }
  });
});
