// Structural review findings: which ones show, what they are anchored to on the map, and where a
// finding leads. Kept free of React so it can be unit tested against the fixture reports.

import { within, type Focus, type Index, type MapGraph } from "./graph";
import type { Anchor, Edge, Finding } from "./types";

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

/** What is left of a finding on the panel of one edge, once the facts the panel already shows are taken out. */
export type EdgeFindingView =
  /** Only the severity and kind, on the status line. */
  | { kind: "chip"; finding: Finding }
  /** The chip and one line of context the panel doesn't otherwise show. */
  | { kind: "line"; finding: Finding; context: string }
  /** The finding with the evidence and anchors that are not this edge again. */
  | { kind: "full"; finding: Finding; evidence: string[]; anchors: Anchor[] };

const MAX_OTHER_USERS = 3;

/**
 * A finding seen from one edge. The edge panel already shows the edge's ends, status and references,
 * so a finding there drops what repeats them. Decided from report data (refs, externalDeps, edges), never
 * from the wording of the finding's text.
 */
export function edgeFindingView(index: Index, edge: Edge, f: Finding): EdgeFindingView {
  if (f.kind === "new-external") {
    const parts: string[] = [];
    const lock = index.report.externalDeps.find((d) => d.change === "added" && "ext:" + d.name === edge.to);
    if (lock) parts.push(lock.to ? `New in the lockfile at ${lock.to}` : "New in the lockfile");
    const name = (id: string) => index.components.get(id)?.name ?? id;
    const others: string[] = [];
    for (const e of index.report.edges) {
      if (e.status !== "added" || e.to !== edge.to || e.from === edge.from || e.from.startsWith("ext:")) continue;
      const n = name(e.from);
      if (!others.includes(n) && n !== name(edge.from)) others.push(n);
    }
    if (others.length > 0) {
      const shown = others.slice(0, MAX_OTHER_USERS).join(", ");
      const more = others.length > MAX_OTHER_USERS ? ` and ${others.length - MAX_OTHER_USERS} more` : "";
      parts.push(`also new in ${shown}${more}`);
    }
    return parts.length > 0 ? { kind: "line", finding: f, context: parts.join(" · ") } : { kind: "chip", finding: f };
  }
  const anchors = f.anchors.filter(
    (a) => !(a.from === edge.from && a.to === edge.to) && !(a.component !== undefined && (a.component === edge.from || a.component === edge.to)),
  );
  let evidence = f.evidence;
  if (f.kind === "layering") {
    // Evidence after the first line (which layers the ends are in) may name references; drop the ones that are this edge's.
    const refEnds = edge.refs.map((r) => (r.line === 0 ? ` in ${r.file}` : ` at ${r.file}:${r.line}`));
    evidence = f.evidence.filter((x, i) => i === 0 || !refEnds.some((end) => x.endsWith(end)));
  }
  return { kind: "full", finding: f, evidence, anchors };
}
