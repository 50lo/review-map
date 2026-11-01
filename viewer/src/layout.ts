// ELK layout for the component map. Split folders are laid out inside their target's group.
// The layout depends only on the set of visible nodes and their edges, never on the focus,
// so selecting things doesn't move the map.

import ELK, { type ElkNode, type ElkExtendedEdge } from "elkjs/lib/elk.bundled.js";
import type { Index } from "./graph";
import type { Edge } from "./types";

export const NODE_W = 210;
export const NODE_H = 60;
export const EXT_W = 210;
export const EXT_H = 36;
const GROUP_PAD_TOP = 40;

export interface Placed {
  id: string;
  x: number; // relative to the parent group, if any
  y: number;
  width: number;
  height: number;
  parent?: string;
  isGroup: boolean;
}

const elk = new ELK();

export async function layout(index: Index, nodes: Set<string>, edges: Edge[]): Promise<Map<string, Placed>> {
  const groupOf = (id: string) => {
    const p = index.components.get(id)?.parent;
    return p && nodes.has(p) ? p : undefined;
  };
  const isGroup = (id: string) => (index.children.get(id) ?? []).some((c) => nodes.has(c));

  const build = (id: string): ElkNode => {
    const c = index.components.get(id)!;
    if (isGroup(id)) {
      const kids = [...nodes].filter((n) => groupOf(n) === id).sort();
      return {
        id,
        layoutOptions: {
          "elk.padding": `[top=${GROUP_PAD_TOP},left=14,bottom=14,right=14]`,
        },
        children: kids.map(build),
      };
    }
    const ext = c.kind === "external";
    return { id, width: ext ? EXT_W : NODE_W, height: ext ? EXT_H : NODE_H };
  };

  // Top-level nodes with no layout edges (directly or through their folders) would end up in
  // one long row. Lay out the connected part with ELK and shelve the rest below it.
  const rootOf = (id: string): string => {
    let cur = id;
    for (let p = groupOf(cur); p; p = groupOf(cur)) cur = p;
    return cur;
  };
  const connected = new Set<string>();
  for (const e of edges) {
    connected.add(rootOf(e.from));
    connected.add(rootOf(e.to));
  }
  const allRoots = [...nodes].filter((n) => !groupOf(n)).sort();
  const roots = allRoots.filter((n) => connected.has(n));
  const loose = allRoots.filter((n) => !connected.has(n));
  const elkEdges: ElkExtendedEdge[] = edges.map((e, i) => ({ id: `e${i}`, sources: [e.from], targets: [e.to] }));
  const graph: ElkNode = {
    id: "root",
    layoutOptions: {
      "elk.algorithm": "layered",
      "elk.direction": "DOWN",
      "elk.hierarchyHandling": "INCLUDE_CHILDREN",
      "elk.layered.spacing.nodeNodeBetweenLayers": "70",
      "elk.spacing.nodeNode": "36",
      "elk.layered.nodePlacement.strategy": "BRANDES_KOEPF",
      "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
    },
    children: roots.map(build),
    edges: elkEdges,
  };

  const out = new Map<string, Placed>();
  const res = await elk.layout(graph);
  const looseRes = await Promise.all(
    loose.map((id) => elk.layout({ id: "root", layoutOptions: graph.layoutOptions, children: [build(id)], edges: [] })),
  );
  const walk = (n: ElkNode, parent?: string) => {
    for (const ch of n.children ?? []) {
      out.set(ch.id, {
        id: ch.id,
        x: ch.x ?? 0,
        y: ch.y ?? 0,
        width: ch.width ?? NODE_W,
        height: ch.height ?? NODE_H,
        parent,
        isGroup: !!ch.children?.length,
      });
      walk(ch, ch.id);
    }
  };
  walk(res);

  // Shelf packing for the loose nodes: components first by change size, then packages.
  const comp = (id: string) => index.components.get(id)!;
  const order = looseRes
    .map((r) => r.children![0])
    .sort((a, b) => {
      const ea = Number(comp(a.id).kind === "external");
      const eb = Number(comp(b.id).kind === "external");
      return ea - eb || comp(b.id).changeScore - comp(a.id).changeScore || a.id.localeCompare(b.id);
    });
  const gap = 24;
  const width = Math.max(res.width ?? 0, 3 * (NODE_W + gap));
  let x = 0;
  let y = res.children?.length ? (res.height ?? 0) + 48 : 0;
  let rowH = 0;
  let lastExternal: boolean | undefined;
  for (const n of order) {
    const ext = comp(n.id).kind === "external";
    const w = n.width ?? NODE_W;
    const h = n.height ?? NODE_H;
    // Packages start their own row.
    if (x > 0 && (x + w > width || (lastExternal !== undefined && ext !== lastExternal))) {
      x = 0;
      y += rowH + gap;
      rowH = 0;
    }
    lastExternal = ext;
    n.x = x;
    n.y = y;
    x += w + gap;
    rowH = Math.max(rowH, h);
  }
  walk({ id: "loose", children: order });
  return out;
}
