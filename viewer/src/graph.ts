// Pure logic for the component map: what is visible, what relates to the focus, and the
// Start here ranking. Kept free of React so it can be unit tested against the fixture model.

import type { Focus } from "./nav";
import type { ChangeModel, Component, Edge, Entity, ExternalDepChange, Region } from "./types";
import { entityKindLabel } from "./languages";

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
  /** True once the analyzer scores regions; before that, ranking falls back to contract flags. */
  hasRegions: boolean;
  /** Review and removed regions per entity, in line order. */
  regionsByEntity: Map<string, Region[]>;
  /** Context regions per entity. */
  contextByEntity: Map<string, Region[]>;
  regions: Map<string, Region>;
  /** Review and removed regions of entities in the default views, highest risk first. */
  riskOrder: Region[];
  /** The model carries LLM annotations. */
  hasLLM: boolean;
  /** The LLM layer is on: ranking uses LLM risk, and LLM summaries, pruning, and review findings are available. */
  llm: boolean;
}

export interface IndexOptions {
  /** Use the LLM layer when the model has it. Default true. */
  llm?: boolean;
}

export const edgeKey = (e: { from: string; to: string }) => `${e.from}->${e.to}`;

export function buildIndex(model: ChangeModel, opts: IndexOptions = {}): Index {
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
  const regionsByEntity = new Map<string, Region[]>();
  const contextByEntity = new Map<string, Region[]>();
  for (const r of model.regions) {
    const m = r.kind === "context" ? contextByEntity : regionsByEntity;
    m.set(r.entity, [...(m.get(r.entity) ?? []), r]);
  }
  const index: Index = {
    model,
    components,
    children,
    externalChange,
    entitiesByComponent,
    entities,
    hasRegions: regionsByEntity.size > 0,
    regionsByEntity,
    contextByEntity,
    regions: new Map(model.regions.map((r) => [r.id, r])),
    riskOrder: [],
    hasLLM: hasLLM(model),
    llm: false,
  };
  index.llm = index.hasLLM && opts.llm !== false;
  const pos = new Map(model.entities.map((e, i) => [e.id, i]));
  index.riskOrder = model.regions
    .filter((r) => r.kind !== "context" && entities.has(r.entity) && !isLowRisk(index, entities.get(r.entity)!))
    .sort((a, b) => regionRisk(index, b) - regionRisk(index, a) || pos.get(a.entity)! - pos.get(b.entity)! || a.startLine - b.startLine);
  return index;
}

/** True when any region, summary, or finding came from the LLM annotator. */
export const hasLLM = (m: ChangeModel) =>
  !!m.llm && (m.regions.some((r) => r.llm) || m.entities.some((e) => e.llm) || (m.findings ?? []).some((f) => f.source === "llm"));

/** The risk a region ranks by: the LLM's when the LLM layer is on and it scored the region, else the deterministic one. */
export const regionRisk = (index: Index, r: Region) => (index.llm ? r.llm?.risk ?? r.risk : r.risk);

/** LLM content of a region, entity, or component, or nothing when the LLM layer is off. */
export const llmOf = <T extends { llm?: unknown }>(index: Index, x: T | undefined): T["llm"] | undefined => (index.llm ? x?.llm : undefined);

/**
 * Context regions of an entity in display order. With the LLM layer on, kept regions come first in
 * the LLM's rank and the ones it pruned are split off; otherwise every region shows, in analyzer order.
 */
export function contextOf(index: Index, entity: string): { shown: Region[]; pruned: Region[] } {
  const all = index.contextByEntity.get(entity) ?? [];
  if (!index.llm || !all.some((c) => c.llm?.keep !== undefined)) return { shown: all, pruned: [] };
  const shown = all.filter((c) => c.llm?.keep !== false).sort((a, b) => (a.llm?.rank ?? 1e9) - (b.llm?.rank ?? 1e9));
  return { shown, pruned: all.filter((c) => c.llm?.keep === false) };
}

/** Risk tier for display: high, medium, or low. */
export const riskTier = (risk: number) => (risk >= 0.6 ? "high" : risk >= 0.3 ? "medium" : "low");

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

/**
 * What the map draws. `expanded` lists components whose direct neighbors are shown too,
 * whatever the scope.
 */
export function visible(index: Index, opts: MapOptions, expanded: ReadonlySet<string> = new Set()): Visible {
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
  for (const e of model.edges) {
    if (!allowed(e.from) || !allowed(e.to)) continue;
    if (expanded.has(e.from)) nodes.add(e.to);
    if (expanded.has(e.to)) nodes.add(e.from);
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

/** The neighbors of a component that the map doesn't show yet. */
export function hiddenNeighbors(index: Index, vis: Visible, id: string, showTests: boolean): string[] {
  const out = new Set<string>();
  const allowed = (x: string) => showTests || !index.components.get(x)?.isTest;
  for (const e of index.model.edges) {
    if (e.from === e.to) continue;
    if (e.from === id && allowed(e.to) && !vis.nodes.has(e.to)) out.add(e.to);
    if (e.to === id && allowed(e.from) && !vis.nodes.has(e.from)) out.add(e.from);
  }
  return [...out].sort();
}

// ---------------------------------------------------------------------------
// Collapsed groups

/** A target split into folders, drawn as a group around them. */
export const isGroupOf = (index: Index, vis: Visible, id: string) => (index.children.get(id) ?? []).some((c) => vis.nodes.has(c));

/** Above this many visible components, groups start collapsed. */
export const COLLAPSE_ABOVE = 40;

/** Groups collapsed when the map opens: all of them on a large map, none on a small one. */
export function defaultCollapsed(index: Index, vis: Visible): Set<string> {
  if (vis.nodes.size <= COLLAPSE_ABOVE) return new Set();
  return new Set([...vis.nodes].filter((id) => isGroupOf(index, vis, id)));
}

/** The components a focus is about, which the map must show. */
function focusComponents(index: Index, focus: Focus): string[] {
  switch (focus?.type) {
    case "component":
    case "interface":
      return [focus.id];
    case "edge": {
      const e = index.model.edges.find((x) => edgeKey(x) === focus.key);
      return e ? [e.from, e.to] : [];
    }
    case "entity": {
      const e = index.entities.get(focus.id);
      return e ? [e.component] : [];
    }
    default:
      return [];
  }
}

/**
 * `collapsed` without the groups that would hide the focus: the groups around it, and for an
 * edge also its ends, which would otherwise draw it inside a bundle. Returns the same set when
 * nothing changes.
 */
export function revealFocus(index: Index, collapsed: Set<string>, focus: Focus): Set<string> {
  const open = new Set<string>();
  for (const id of focusComponents(index, focus)) {
    const first = focus?.type === "edge" ? id : index.components.get(id)?.parent;
    for (let p = first; p; p = index.components.get(p)?.parent) {
      if (collapsed.has(p)) open.add(p);
    }
  }
  if (open.size === 0) return collapsed;
  return new Set([...collapsed].filter((id) => !open.has(id)));
}

/** An edge as drawn: a model edge, or a bundle of them when an end is a collapsed group. */
export interface MapEdge {
  /** The model edge's key, or a bundle key. */
  key: string;
  from: string;
  to: string;
  status: Edge["status"];
  refCount: number;
  bundle: boolean;
  members: Edge[];
}

export interface MapGraph {
  nodes: Set<string>;
  edges: MapEdge[];
  /** Collapsed groups drawn as single nodes, with the number of components they hide. */
  collapsed: Map<string, number>;
}

export const bundleKey = (from: string, to: string) => `bundle:${from}->${to}`;

/** True when `id` is `root` or inside it. */
export function within(index: Index, id: string, root: string): boolean {
  for (let cur: string | undefined = id; cur; cur = index.components.get(cur)?.parent) if (cur === root) return true;
  return false;
}

/** The model edges a bundle between two drawn nodes stands for. */
export const bundleMembers = (index: Index, from: string, to: string) =>
  index.model.edges.filter((e) => within(index, e.from, from) && within(index, e.to, to));

/** One status for several edges: theirs when they agree, else changed. */
export function mergeStatus(edges: Edge[]): Edge["status"] {
  const statuses = new Set(edges.map((e) => e.status));
  return statuses.size === 1 ? edges[0].status : "changed";
}

/** The map with collapsed groups drawn as one node each, and the edges into them bundled. */
export function collapse(index: Index, vis: Visible, collapsed: ReadonlySet<string>): MapGraph {
  const rep = (id: string) => {
    let out = id;
    for (let p = index.components.get(id)?.parent; p; p = index.components.get(p)?.parent) {
      if (collapsed.has(p) && vis.nodes.has(p)) out = p;
    }
    return out;
  };
  const nodes = new Set<string>();
  const hidden = new Map<string, number>();
  for (const id of vis.nodes) {
    const r = rep(id);
    nodes.add(r);
    if (r !== id) hidden.set(r, (hidden.get(r) ?? 0) + 1);
  }
  const byEnds = new Map<string, { from: string; to: string; members: Edge[] }>();
  for (const e of vis.edges) {
    const from = rep(e.from);
    const to = rep(e.to);
    if (from === to) continue;
    const k = `${from}\n${to}`;
    const b = byEnds.get(k) ?? { from, to, members: [] };
    b.members.push(e);
    byEnds.set(k, b);
  }
  const edges: MapEdge[] = [...byEnds.values()].map(({ from, to, members }) => {
    const single = members.length === 1 && members[0].from === from && members[0].to === to;
    return {
      key: single ? edgeKey(members[0]) : bundleKey(from, to),
      from,
      to,
      status: mergeStatus(members),
      refCount: members.reduce((n, e) => n + (e.refCount ?? e.refs.length), 0),
      bundle: !single,
      members,
    };
  });
  const collapsedNodes = new Map([...hidden].filter(([id]) => collapsed.has(id)));
  return { nodes, edges, collapsed: collapsedNodes };
}

/** Change counts of a component together with everything inside it, for a collapsed group. */
export function rollup(index: Index, id: string): { changedEntities: number; interfaceChanges: number; changeScore: number; changed: boolean } {
  const out = { changedEntities: 0, interfaceChanges: 0, changeScore: 0, changed: false };
  for (const c of index.model.components) {
    if (!within(index, c.id, id)) continue;
    out.changedEntities += c.changedEntities;
    out.interfaceChanges += c.interfaceChanges;
    out.changeScore = Math.max(out.changeScore, c.changeScore || 0);
    out.changed ||= isChanged(index, c);
  }
  return out;
}

// ---------------------------------------------------------------------------

export interface Related {
  nodes: Set<string>;
  edges: Set<string>;
}

/** What stays prominent around the focus. Null focus means everything is prominent. */
export function related(index: Index, edges: Array<{ key: string; from: string; to: string }>, focus: Focus): Related | null {
  focus = mapFocus(index, focus);
  if (!focus) return null;
  const nodes = new Set<string>();
  const keys = new Set<string>();
  if (focus.type === "component") {
    nodes.add(focus.id);
    for (const e of edges) {
      if (e.from === focus.id || e.to === focus.id) {
        keys.add(e.key);
        nodes.add(e.from);
        nodes.add(e.to);
      }
    }
    // A group stays lit when one of its folders is the focus, and the reverse.
    const c = index.components.get(focus.id);
    if (c?.parent) nodes.add(c.parent);
    for (const child of index.children.get(focus.id) ?? []) nodes.add(child);
  } else if (focus.type === "edge" || focus.type === "bundle") {
    const key = focus.type === "edge" ? focus.key : bundleKey(focus.from, focus.to);
    const e = edges.find((x) => x.key === key);
    if (e) {
      keys.add(key);
      nodes.add(e.from);
      nodes.add(e.to);
    } else if (focus.type === "bundle") {
      nodes.add(focus.from);
      nodes.add(focus.to);
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

/** Entity kinds as the entity's language names them. */
export const kindLabel = entityKindLabel;

/** A contract flag without its language prefix: "swift:codable-shape" -> "codable-shape". */
export const flagName = (flag: string): string => flag.replace(/^[a-z0-9]+:/, "");

/** Flag weights for ranking a model without regions: concurrency and persisted models rank highest. */
const flagWeight = (prefixed: string): number => {
  const flag = flagName(prefixed);
  if (/^(mainactor|nonisolated|sendable|async|conformance-isolation|kind-changed|default-isolation|strict-concurrency)/.test(flag)) return 3;
  if (/^(codable-shape|swiftdata|coredata|core-data)/.test(flag)) return 3;
  if (/^(protocol-requirement|access-changed|enum-case|conformance-|throws|typed-throws|entitlements|privacy|url-schemes|observable)/.test(flag)) return 2;
  if (/^(interface-member|enum-member|abstract-member|supertype-|export-removed|package-exports)/.test(flag)) return 2;
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
  /** Top region id, or entity id in the interim ranking. */
  id: string;
  /** The entity the row names: the top region's entity, or the type it is a member of. */
  entity: Entity;
  /** Where the row leads: the highest-risk region. */
  focus: Focus;
  score: number;
  reasons: string[];
  /** Member entities folded into this item. */
  members: Entity[];
  /** Review and removed regions behind the item. */
  regionCount: number;
  source: "regions" | "flags";
}

/** Reasons the analyzer gives a region that has no specific risk signal. */
const FALLBACK_REASONS = new Set(["changed lines", "new declaration", "removed declaration", "removed lines", "signature changed", "modifiers changed", "changed", "new file", "removed file"]);

export function isLowRisk(index: Index, e: Entity): boolean {
  const c = index.components.get(e.component);
  return e.change === "cosmetic" || !!e.tags?.some((t) => t === "test" || t === "generated") || !!c?.isTest;
}

/** Highest region risk of an entity, or the contract-flag score before regions exist. */
export function entityRank(index: Index, e: Entity): number {
  if (!index.hasRegions) return entityScore(e);
  return Math.max(0, ...(index.regionsByEntity.get(e.id) ?? []).map((r) => regionRisk(index, r)));
}

/**
 * The highest-risk places in the change. With regions, each item is an entity (with its changed
 * members folded in) scored by its riskiest region; before regions exist, entities are ranked by
 * their contract flags.
 */
export function startHere(index: Index, limit = 10): StartItem[] {
  const { model } = index;
  const fromRegions = index.hasRegions;
  const candidates = model.entities.filter((e) =>
    fromRegions ? !isLowRisk(index, e) && index.regionsByEntity.has(e.id) : !isLowRisk(index, e) && entityScore(e) > 0,
  );
  // Fold members into their listed parent, so one Codable type doesn't fill the whole list.
  const listed = new Set(candidates.map((e) => e.id));
  const rootOf = (e: Entity): string => {
    let cur = e;
    while (cur.parent && listed.has(cur.parent)) cur = index.entities.get(cur.parent)!;
    return cur.id;
  };
  const groups = new Map<string, StartItem & { ranked: Array<{ risk: number; reasons: string[] }> }>();
  for (const e of candidates) {
    const root = rootOf(e);
    let item = groups.get(root);
    if (!item) {
      const r = index.entities.get(root)!;
      item = { id: root, entity: r, focus: { type: "entity", id: root }, score: -1, reasons: [], members: [], regionCount: 0, source: fromRegions ? "regions" : "flags", ranked: [] };
      groups.set(root, item);
    }
    if (e.id !== root) item.members.push(e);
    if (fromRegions) {
      for (const r of index.regionsByEntity.get(e.id)!) {
        item.regionCount++;
        const risk = regionRisk(index, r);
        item.ranked.push({ risk, reasons: r.reasons });
        if (risk > item.score) {
          item.score = risk;
          item.id = r.id;
          item.focus = { type: "entity", id: r.entity, region: r.id };
        }
      }
    } else {
      item.score = Math.max(item.score, entityScore(e));
      item.ranked.push({ risk: entityScore(e), reasons: e.contractFlags });
    }
  }
  return [...groups.values()]
    .map(({ ranked, ...g }) => {
      const reasons: string[] = [];
      let usage = 0;
      for (const r of ranked.sort((a, b) => b.risk - a.risk)) {
        for (const x of r.reasons) {
          const used = /^used from (\d+) /.exec(x);
          if (used) usage = Math.max(usage, Number(used[1]));
          else if (!reasons.includes(x) && !FALLBACK_REASONS.has(x)) reasons.push(x);
        }
      }
      if (usage) reasons.push(`used from ${usage} component${usage === 1 ? "" : "s"}`);
      return { ...g, reasons: reasons.length ? reasons : [ranked[0]?.reasons[0] ?? g.entity.change] };
    })
    .sort((a, b) => b.score - a.score || a.entity.qualifiedName.localeCompare(b.entity.qualifiedName))
    .slice(0, limit);
}

/** Where the region shortcuts go from the current focus: the next or previous region in risk order. */
export function stepRegion(index: Index, focus: Focus, dir: 1 | -1): Focus {
  const order = index.riskOrder;
  if (order.length === 0) return focus;
  let target: number;
  const at = focus?.type === "entity" && focus.region ? order.findIndex((r) => r.id === focus.region) : -1;
  const entityFirst = focus?.type === "entity" ? order.findIndex((r) => r.entity === focus.id) : -1;
  if (at >= 0) target = at + dir;
  // On an entity with no region in focus, next enters its riskiest region.
  else if (entityFirst >= 0) target = dir === 1 ? entityFirst : entityFirst - 1;
  else target = dir === 1 ? 0 : order.length - 1;
  if (target < 0 || target >= order.length) return focus;
  return toFocus(order[target]);
}

const toFocus = (r: Region): Focus => ({ type: "entity", id: r.entity, region: r.id });

/** 1-based position of the focused region in risk order, or 0. */
export function regionPosition(index: Index, focus: Focus): number {
  if (focus?.type !== "entity" || !focus.region) return 0;
  return index.riskOrder.findIndex((r) => r.id === focus.region) + 1;
}

/** Entities of a component for the side panel: interface changes first, cosmetic counted separately. */
export function componentEntities(index: Index, id: string): { shown: Entity[]; cosmetic: number; lowRisk: number } {
  const all = index.entitiesByComponent.get(id) ?? [];
  const cosmetic = all.filter((e) => e.change === "cosmetic").length;
  const lowRisk = all.filter((e) => e.change !== "cosmetic" && isLowRisk(index, e)).length;
  const shown = all
    .filter((e) => e.change !== "cosmetic" && !isLowRisk(index, e))
    .sort((a, b) => Number(b.isInterface) - Number(a.isInterface) || entityRank(index, b) - entityRank(index, a));
  return { shown, cosmetic, lowRisk };
}

/** "spm:Features/Checkout" → "Checkout" when drawn inside its "Features" group. */
export function shortName(index: Index, c: Component): string {
  const p = c.parent ? index.components.get(c.parent) : undefined;
  if (p && c.name.startsWith(p.name + "/")) return c.name.slice(p.name.length + 1);
  return c.name;
}

/** Human form of a contract flag: "async-added" → "async added". */
export function flagLabel(flag: string): string {
  const f = flagName(flag);
  const i = f.indexOf(":");
  const name = (i < 0 ? f : f.slice(0, i)).replace(/-/g, " ");
  return i < 0 ? name : `${name}: ${f.slice(i + 1).replace("->", " → ")}`;
}
