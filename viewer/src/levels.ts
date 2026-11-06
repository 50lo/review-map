// Pure logic for levels 2 and 3: how a component's review items are grouped and ordered, and where
// a reference leads. Kept free of React so it can be tested against the fixture report.

import { componentReviewItems, reviewItemRank, type Index } from "./graph";
import type { Focus } from "./nav";
import type { ReviewItem, Usage } from "./types";

export const KIND_GROUPS: Array<{ title: string; kinds: string[] }> = [
  { title: "Protocols and interfaces", kinds: ["protocol"] },
  { title: "Types", kinds: ["struct", "class", "enum", "actor", "extension", "typealias"] },
  { title: "Functions", kinds: ["func", "init"] },
  { title: "Properties", kinds: ["var"] },
  { title: "Enum cases and members", kinds: ["case"] },
  { title: "Files and build settings", kinds: ["file", "target"] },
];

export interface InterfaceModel {
  /** Changed interface review items, grouped by kind, most significant first within a group. */
  groups: Array<{ title: string; reviewItems: ReviewItem[] }>;
  /** Changed internal review items, shown collapsed below the interface. */
  internal: ReviewItem[];
  /** Cosmetic, test, and generated changes, reachable through a filter. */
  hidden: ReviewItem[];
}


export function interfaceModel(index: Index, componentId: string): InterfaceModel {
  const byScore = (a: ReviewItem, b: ReviewItem) => reviewItemRank(index, b) - reviewItemRank(index, a) || a.qualifiedName.localeCompare(b.qualifiedName);
  const { shown } = componentReviewItems(index, componentId);
  const shownIds = new Set(shown.map((e) => e.id));
  const hidden = (index.reviewItemsByComponent.get(componentId) ?? []).filter((e) => !shownIds.has(e.id));
  const iface = shown.filter((e) => e.isInterface);
  const groups = KIND_GROUPS.map((g) => ({ title: g.title, reviewItems: iface.filter((e) => g.kinds.includes(e.kind)).sort(byScore) }));
  const known = new Set(KIND_GROUPS.flatMap((g) => g.kinds));
  const other = iface.filter((e) => !known.has(e.kind)).sort(byScore);
  if (other.length) groups.push({ title: "Other", reviewItems: other });
  return {
    groups: groups.filter((g) => g.reviewItems.length > 0),
    internal: shown.filter((e) => !e.isInterface).sort(byScore),
    hidden,
  };
}

/** The order level 3 steps through with previous and next: the interface view's order. */
export function reviewOrder(index: Index, componentId: string): ReviewItem[] {
  const m = interfaceModel(index, componentId);
  return [...m.groups.flatMap((g) => g.reviewItems), ...m.internal, ...m.hidden];
}

export function neighbors(index: Index, e: ReviewItem): { prev?: ReviewItem; next?: ReviewItem; position: number; total: number } {
  const order = reviewOrder(index, e.component);
  const i = order.findIndex((x) => x.id === e.id);
  return { prev: i > 0 ? order[i - 1] : undefined, next: i >= 0 ? order[i + 1] : undefined, position: i + 1, total: order.length };
}

/** A review item in the report by component and qualified name, if that declaration changed. */
export function findReviewItem(index: Index, component: string, qualifiedName: string): ReviewItem | undefined {
  const direct = index.reviewItems.get(`${component}::${qualifiedName}`);
  if (direct) return direct;
  return index.reviewItemsByComponent.get(component)?.find((e) => e.qualifiedName === qualifiedName);
}

/**
 * Where a "used by" reference leads: the referring declaration when it changed too, otherwise
 * the line that makes the reference.
 */
export function usedByTarget(index: Index, u: Usage): Focus {
  const e = findReviewItem(index, u.component, u.symbol);
  return e ? { type: "reviewItem", id: e.id } : { type: "location", side: "head", file: u.file, line: u.line };
}

/**
 * Where a "depends on" reference leads: the referenced declaration when it changed, otherwise
 * the interface view of the component that declares it.
 */
export function dependsOnTarget(index: Index, u: Usage): Focus {
  const e = findReviewItem(index, u.component, u.symbol);
  return e ? { type: "reviewItem", id: e.id } : { type: "interface", id: u.component };
}

/** Usages grouped by component, components with the most usages first. */
export function groupUsages(usages: Usage[], index?: Index): Array<{ component: string; usages: Usage[] }> {
  const m = new Map<string, Usage[]>();
  for (const u of usages) m.set(u.component, [...(m.get(u.component) ?? []), u]);
  const isTest = (id: string) => !!index?.components.get(id)?.isTest;
  return [...m]
    .map(([component, usages]) => ({ component, usages }))
    .sort((a, b) => Number(isTest(a.component)) - Number(isTest(b.component)) || b.usages.length - a.usages.length);
}

/** Changed members of a type, for its level 3 view. */
export const membersOf = (index: Index, e: ReviewItem) => index.report.reviewItems.filter((x) => x.parent === e.id);

/** The last part of a qualified name: "Cart.total()" → "total()". */
export function lastName(qualifiedName: string): string {
  // Dots inside an argument list ("f(a.b:)") are not separators.
  let depth = 0;
  for (let i = qualifiedName.length - 1; i >= 0; i--) {
    const ch = qualifiedName[i];
    if (ch === ")") depth++;
    else if (ch === "(") depth--;
    else if (ch === "." && depth === 0) return qualifiedName.slice(i + 1);
  }
  return qualifiedName;
}

/**
 * Identifiers in code that lead somewhere in the tool: changed top-level types in the report,
 * and the declarations a review item depends on in other components. Ambiguous names are left out.
 */
export function symbolTargets(index: Index, e?: ReviewItem): Map<string, Focus> {
  const out = new Map<string, Focus>();
  const ambiguous = new Set<string>();
  const add = (name: string, f: Focus) => {
    if (!/^[A-Za-z_]\w*$/.test(name) || ambiguous.has(name)) return;
    const prev = out.get(name);
    if (prev && JSON.stringify(prev) !== JSON.stringify(f)) {
      out.delete(name);
      ambiguous.add(name);
      return;
    }
    out.set(name, f);
  };
  for (const x of index.report.reviewItems) {
    if (["struct", "class", "enum", "actor", "protocol", "typealias"].includes(x.kind) && !x.qualifiedName.includes(".") && x.change !== "removed") {
      add(x.qualifiedName, { type: "reviewItem", id: x.id });
    }
  }
  for (const u of e?.dependsOn ?? []) {
    const name = u.symbol.includes(".") ? lastName(u.symbol) : u.symbol;
    if (!out.has(name)) add(name, dependsOnTarget(index, u));
  }
  if (e) out.delete(lastName(e.qualifiedName).replace(/\(.*$/, ""));
  return out;
}
