// Pure logic for the component map: what is visible, what relates to the focus, and the
// Start here ranking. Kept free of React so it can be unit tested against the fixture model.

import type { Focus } from "./nav";
import type { ChangeModel, Component, Edge, Entity, ExternalDepChange, Region } from "./types";

export type { Focus } from "./nav";

export interface MapOptions {
  /**
   * "changed": changed components, plus the ends of added, removed, and changed edges.
   * "neighbors": also every direct neighbor over unchanged edges.
   * "all": the whole system.
   */
  scope: "changed" | "neighbors" | "all";
  showTests: boolean;
}

export interface Index {
  model: ChangeModel;
  components: Map<string, Component>;
  children: Map<string, string[]>;
  externalChange: Map<string, ExternalDepChange>;
  entitiesByComponent: Map<string, Entity[]>;
  entities: Map<string, Entity>;
}

export const edgeKey = (e: { from: string; to: string }) => `${e.from}->${e.to}`;

export function buildIndex(model: ChangeModel): Index {
  const components = new Map(model.components.map((c) => [c.id, c]));
  const children = new Map<string, string[]>();
  for (const c of model.components) {
    if (c.parent && components.has(c.parent)) {
      children.set(c.parent, [...(children.get(c.parent) ?? []), c.id]);
    }
  }
  const externalChange = new Map(model.externalDeps.map((d) => [d.name, d]));
  const entitiesByComponent = new Map<string, Entity[]>();
  for (const e of model.entities) {
    entitiesByComponent.set(e.component, [...(entitiesByComponent.get(e.component) ?? []), e]);
  }
  const entities = new Map(model.entities.map((e) => [e.id, e]));
  return { model, components, children, externalChange, entitiesByComponent, entities };
}

export function externalChangeOf(index: Index, c: Component): ExternalDepChange | undefined {
  if (c.kind !== "external") return undefined;
  return index.externalChange.get(c.name);
}

/** True when the component itself changed, as opposed to only being next to a change. */
export function isChanged(index: Index, c: Component): boolean {
  return c.changedEntities > 0 || !!c.status || !!externalChangeOf(index, c);
}

export const isTestComponent = (c: Component) => !!c.isTest;

export interface Visible {
  /** Components drawn on the map (including group parents of visible children). */
  nodes: Set<string>;
  /** Edges whose ends are both drawn. */
  edges: Edge[];
  /** Components left out by the test filter. */
  hiddenTests: number;
  /** Components left out by the "changed" scope. */
  hiddenUnrelated: number;
}

export function visible(index: Index, opts: MapOptions): Visible {
  const { model } = index;
  const allowed = (id: string) => {
    const c = index.components.get(id);
    return !!c && (opts.showTests || !isTestComponent(c));
  };
  const nodes = new Set<string>();
  if (opts.scope === "all") {
    for (const c of model.components) if (allowed(c.id)) nodes.add(c.id);
  } else {
    const changed = new Set<string>();
    for (const c of model.components) if (allowed(c.id) && isChanged(index, c)) changed.add(c.id);
    for (const e of model.edges) {
      if (e.status !== "unchanged" && allowed(e.from) && allowed(e.to)) {
        changed.add(e.from);
        changed.add(e.to);
      }
    }
    for (const id of changed) nodes.add(id);
    if (opts.scope === "neighbors") {
      for (const e of model.edges) {
        if (!allowed(e.from) || !allowed(e.to)) continue;
        if (changed.has(e.from)) nodes.add(e.to);
        if (changed.has(e.to)) nodes.add(e.from);
      }
    }
  }
  // A visible split folder pulls in its target, which is drawn as a group around it.
  for (const id of [...nodes]) {
    let p = index.components.get(id)?.parent;
    while (p && index.components.has(p)) {
      nodes.add(p);
      p = index.components.get(p)?.parent;
    }
  }
  const edges = model.edges.filter((e) => nodes.has(e.from) && nodes.has(e.to) && e.from !== e.to);
  const hiddenTests = opts.showTests ? 0 : model.components.filter(isTestComponent).length;
  const hiddenUnrelated = model.components.length - nodes.size - hiddenTests;
  return { nodes, edges, hiddenTests, hiddenUnrelated: Math.max(0, hiddenUnrelated) };
}

export interface Related {
  nodes: Set<string>;
  edges: Set<string>;
}

/** What stays prominent around the focus. Null focus means everything is prominent. */
export function related(index: Index, edges: Edge[], focus: Focus): Related | null {
  focus = mapFocus(index, focus);
  if (!focus) return null;
  const nodes = new Set<string>();
  const keys = new Set<string>();
  if (focus.type === "component") {
    nodes.add(focus.id);
    for (const e of edges) {
      if (e.from === focus.id || e.to === focus.id) {
        keys.add(edgeKey(e));
        nodes.add(e.from);
        nodes.add(e.to);
      }
    }
    // A group stays lit when one of its folders is the focus, and the reverse.
    const c = index.components.get(focus.id);
    if (c?.parent) nodes.add(c.parent);
    for (const child of index.children.get(focus.id) ?? []) nodes.add(child);
  } else if (focus.type === "edge") {
    const key = focus.key;
    const e = edges.find((x) => edgeKey(x) === key);
    if (e) {
      keys.add(key);
      nodes.add(e.from);
      nodes.add(e.to);
    }
  }
  // Parents of lit nodes are drawn around them, so keep them lit too.
  for (const id of [...nodes]) {
    const p = index.components.get(id)?.parent;
    if (p) nodes.add(p);
  }
  return { nodes, edges: keys };
}

/**
 * The map's focus for any focus: the component of an interface or entity view, so the map
 * still shows where you are when you go back to it.
 */
export function mapFocus(index: Index, focus: Focus): Focus {
  if (focus?.type === "interface") return { type: "component", id: focus.id };
  if (focus?.type === "entity") {
    const e = index.entities.get(focus.id);
    return e ? { type: "component", id: e.component } : null;
  }
  if (focus?.type === "location") return null;
  return focus;
}

export interface ComponentEdges {
  outgoing: Record<Edge["status"], Edge[]>;
  incoming: Record<Edge["status"], Edge[]>;
}

const emptyByStatus = (): Record<Edge["status"], Edge[]> => ({ added: [], removed: [], changed: [], unchanged: [] });

export function componentEdges(model: ChangeModel, id: string): ComponentEdges {
  const out = { outgoing: emptyByStatus(), incoming: emptyByStatus() };
  for (const e of model.edges) {
    if (e.from === id) out.outgoing[e.status].push(e);
    if (e.to === id) out.incoming[e.status].push(e);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Start here

/**
 * Flag weights for the interim ranking used until the analyzer emits risk regions
 * (milestone 4). They follow the brief's table: concurrency and persisted or networked
 * models are high, other contract changes medium.
 */
const flagWeight = (flag: string): number => {
  if (/^(mainactor|nonisolated|sendable|async|conformance-isolation|kind-changed|default-isolation|strict-concurrency)/.test(flag)) return 3;
  if (/^(codable-shape|swiftdata|coredata|core-data)/.test(flag)) return 3;
  if (/^(protocol-requirement|access-changed|enum-case|conformance-|throws|typed-throws|entitlements|privacy|url-schemes|observable)/.test(flag)) return 2;
  return 1;
};

const changeWeight: Record<string, number> = { removed: 1.5, signature: 1.2, added: 1, modifiers: 1, body: 0.6, cosmetic: 0 };

export function entityScore(e: Entity): number {
  if (e.change === "cosmetic") return 0;
  const flags = e.contractFlags.reduce((s, f) => s + flagWeight(f), 0);
  const base = flags + (changeWeight[e.change] ?? 0.5);
  const crossUse = Math.min(e.usedBy?.length ?? 0, 10) * 0.1;
  return (base + crossUse) * (e.isInterface ? 1.5 : 1);
}

export interface StartItem {
  /** Region id or entity id. */
  id: string;
  entity: Entity;
  score: number;
  reasons: string[];
  /** Member entities folded into this item (interim ranking only). */
  members: Entity[];
  source: "regions" | "flags";
}

function isLowRisk(index: Index, e: Entity): boolean {
  const c = index.components.get(e.component);
  return e.change === "cosmetic" || !!e.tags?.some((t) => t === "test" || t === "generated") || !!c?.isTest;
}

export function startHere(index: Index, limit = 10): StartItem[] {
  const { model } = index;
  const reviewRegions = model.regions.filter((r: Region) => r.kind !== "context");
  if (reviewRegions.length > 0) {
    return reviewRegions
      .map((r) => ({ r, e: index.entities.get(r.entity) }))
      .filter((x): x is { r: Region; e: Entity } => !!x.e && !isLowRisk(index, x.e))
      .map(({ r, e }) => ({ id: r.id, entity: e, score: r.llm?.risk ?? r.risk, reasons: r.reasons, members: [], source: "regions" as const }))
      .sort((a, b) => b.score - a.score)
      .slice(0, limit);
  }

  // Interim: rank entities by contract flags, folding members into their listed parent
  // so one Codable type doesn't fill the whole list.
  const candidates = model.entities.filter((e) => !isLowRisk(index, e) && entityScore(e) > 0);
  const listed = new Set(candidates.map((e) => e.id));
  const rootOf = (e: Entity): string => {
    let cur = e;
    while (cur.parent && listed.has(cur.parent)) cur = index.entities.get(cur.parent)!;
    return cur.id;
  };
  const groups = new Map<string, StartItem>();
  for (const e of candidates) {
    const root = rootOf(e);
    const score = entityScore(e);
    let item = groups.get(root);
    if (!item) {
      const r = index.entities.get(root)!;
      item = { id: root, entity: r, score: 0, reasons: [], members: [], source: "flags" };
      groups.set(root, item);
    }
    if (e.id !== root) item.members.push(e);
    item.score = Math.max(item.score, score);
    for (const f of e.contractFlags) if (!item.reasons.includes(f)) item.reasons.push(f);
  }
  return [...groups.values()]
    .map((g) => (g.reasons.length === 0 ? { ...g, reasons: [g.entity.change] } : g))
    .sort((a, b) => b.score - a.score || a.entity.qualifiedName.localeCompare(b.entity.qualifiedName))
    .slice(0, limit);
}

/** Entities of a component for the side panel: interface changes first, cosmetic counted separately. */
export function componentEntities(index: Index, id: string): { shown: Entity[]; cosmetic: number; lowRisk: number } {
  const all = index.entitiesByComponent.get(id) ?? [];
  const cosmetic = all.filter((e) => e.change === "cosmetic").length;
  const lowRisk = all.filter((e) => e.change !== "cosmetic" && isLowRisk(index, e)).length;
  const shown = all
    .filter((e) => e.change !== "cosmetic" && !isLowRisk(index, e))
    .sort((a, b) => Number(b.isInterface) - Number(a.isInterface) || entityScore(b) - entityScore(a));
  return { shown, cosmetic, lowRisk };
}

/** "spm:Features/Checkout" → "Checkout" when drawn inside its "Features" group. */
export function shortName(index: Index, c: Component): string {
  const p = c.parent ? index.components.get(c.parent) : undefined;
  if (p && c.name.startsWith(p.name + "/")) return c.name.slice(p.name.length + 1);
  return c.name;
}

/** Human form of a contract flag: "async-added" → "async added". */
export function flagLabel(f: string): string {
  const i = f.indexOf(":");
  const name = (i < 0 ? f : f.slice(0, i)).replace(/-/g, " ");
  return i < 0 ? name : `${name}: ${f.slice(i + 1).replace("->", " → ")}`;
}
