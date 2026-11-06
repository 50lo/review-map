// Structural review findings: which ones show, what they are anchored to on the map, and where a
// finding leads. Kept free of React so it can be unit tested against the fixture reports.

import { within, type Focus, type Index, type MapGraph } from "./graph";
import type { Anchor, Finding } from "./types";

export const SEVERITY_ORDER: Record<string, number> = { high: 0, medium: 1, low: 2 };

export const KIND_LABEL: Record<string, string> = {
  cycle: "dependency cycle",
  layering: "layering",
  "new-external": "new dependency",
  "unused-api": "unused API",
  orphaned: "left unused",
  conformers: "conformers",
  untested: "untested",
  intent: "intent",
  placement: "placement",
  missing: "missing",
  duplicate: "duplicate",
  complexity: "complexity",
};

/** The findings that show: every deterministic one, and the LLM's when the LLM layer is on. Most severe first. */
export function findingsOf(index: Index): Finding[] {
  const all = (index.report.findings ?? []).filter((f) => f.source !== "llm" || index.llm);
  return all
    .map((f, i) => ({ f, i }))
    .sort((a, b) => (SEVERITY_ORDER[a.f.severity] ?? 3) - (SEVERITY_ORDER[b.f.severity] ?? 3) || a.i - b.i)
    .map((x) => x.f);
}

/** The component an anchor sits on: its own, its review item's, or (for an edge) none. */
const anchorComponent = (index: Index, a: Anchor) => a.component ?? (a.reviewItem ? index.reviewItems.get(a.reviewItem)?.component : undefined);

/** Findings anchored to a component, to a review item in it, or to an edge out of or into it. */
export function findingsForComponent(index: Index, id: string, opts: { inside?: boolean } = {}): Finding[] {
  const hit = (c?: string) => !!c && (opts.inside ? within(index, c, id) : c === id);
  return findingsOf(index).filter((f) => f.anchors.some((a) => hit(anchorComponent(index, a))));
}

export function findingsForEdge(index: Index, from: string, to: string): Finding[] {
  return findingsOf(index).filter((f) => f.anchors.some((a) => a.from === from && a.to === to));
}

export function findingsForReviewItem(index: Index, id: string): Finding[] {
  return findingsOf(index).filter((f) => f.anchors.some((a) => a.reviewItem === id));
}

/** Findings per drawn node and per drawn edge key, with collapsed groups standing for what they hide. */
export function findingCounts(index: Index, graph: MapGraph): { nodes: Map<string, Finding[]>; edges: Map<string, Finding[]> } {
  const nodes = new Map<string, Finding[]>();
  const edges = new Map<string, Finding[]>();
  const add = (m: Map<string, Finding[]>, k: string, f: Finding) => {
    const list = m.get(k) ?? [];
    if (!list.includes(f)) m.set(k, [...list, f]);
  };
  // The drawn node a component is in: itself, or the outermost collapsed group around it.
  const drawn = (id: string): string | undefined => {
    let out: string | undefined = graph.nodes.has(id) ? id : undefined;
    for (let p = index.components.get(id)?.parent; p; p = index.components.get(p)?.parent) {
      if (graph.collapsed.has(p)) out = p;
      else if (!out && graph.nodes.has(p)) out = p;
    }
    return out;
  };
  for (const f of findingsOf(index)) {
    for (const a of f.anchors) {
      const c = anchorComponent(index, a);
      if (c) {
        const n = drawn(c);
        if (n) add(nodes, n, f);
      } else if (a.from && a.to) {
        for (const e of graph.edges) {
          if (e.members.some((m) => m.from === a.from && m.to === a.to)) add(edges, e.key, f);
        }
      }
    }
  }
  return { nodes, edges };
}

/** Where a finding leads: the code it is about, its main review item, edge, or component. */
export function findingFocus(index: Index, f: Finding): Focus {
  const main = f.anchors[0];
  if (main?.reviewItem && index.reviewItems.has(main.reviewItem)) return { type: "reviewItem", id: main.reviewItem };
  if (f.location && f.location.side === "head") return { type: "location", side: "head", file: f.location.file, line: f.location.startLine };
  if (main?.from && main.to) return { type: "edge", key: `${main.from}->${main.to}` };
  if (main?.component && index.components.has(main.component)) return { type: "component", id: main.component };
  return null;
}

/** The highest severity among findings, for a badge's color. */
export const topSeverity = (fs: Finding[]) =>
  fs.reduce<string | undefined>((top, f) => (top === undefined || (SEVERITY_ORDER[f.severity] ?? 3) < (SEVERITY_ORDER[top] ?? 3) ? f.severity : top), undefined);
