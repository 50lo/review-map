import { memo, useEffect, useMemo, useState } from "react";
import {
  ReactFlow,
  Background,
  Controls,
  Handle,
  MarkerType,
  Position,
  useReactFlow,
  ReactFlowProvider,
  type Edge as RFEdge,
  type Node as RFNode,
  type NodeProps,
} from "@xyflow/react";
import { componentEntities, externalChangeOf, isChanged, related, rollup, shortName, within, type Focus, type Index, type MapGraph } from "./graph";
import { useReview } from "./review";
import { layout, type Placed } from "./layout";
import type { Component, ExternalDepChange } from "./types";

export const EDGE_COLORS: Record<string, string> = {
  added: "var(--added)",
  removed: "var(--removed)",
  changed: "var(--changed)",
  unchanged: "var(--unchanged)",
};

// Edges away from the focus, and unchanged edges, are drawn in muted colors rather than with
// opacity: on a large map, a selection that made hundreds of elements translucent left parts of
// the page unpainted.
const QUIET_UNCHANGED = "var(--edge-quiet)";
const DIMMED = "var(--edge-dim)";

interface NodeData extends Record<string, unknown> {
  comp: Component;
  label: string;
  ext?: ExternalDepChange;
  changed: boolean;
  dim: boolean;
  selected: boolean;
  /** Reviewed entities out of the ones the component's views list. */
  progress?: { done: number; total: number };
  /** Set on groups: collapsed state, how many components a collapsed one hides, and the toggle. */
  group?: { collapsed: boolean; hides: number; toggle: () => void };
  /** Change counts and score, rolled up over a collapsed group's contents. */
  counts: { changedEntities: number; interfaceChanges: number };
  score: number;
}

const Handles = () => (
  <>
    <Handle type="target" position={Position.Top} isConnectable={false} />
    <Handle type="source" position={Position.Bottom} isConnectable={false} />
  </>
);

const statusClass = (c: Component) => (c.status === "added" ? "st-added" : c.status === "removed" ? "st-removed" : "");

const Badges = ({ counts }: { counts: NodeData["counts"] }) =>
  counts.changedEntities > 0 ? (
    <span className="badges">
      <span className="badge" title="Changed entities">
        {counts.changedEntities} changed
      </span>
      {counts.interfaceChanges > 0 && (
        <span className="badge iface" title="Interface changes">
          {counts.interfaceChanges} interface
        </span>
      )}
    </span>
  ) : null;

/** Collapses or expands a group without selecting it. */
const GroupToggle = ({ group }: { group: NonNullable<NodeData["group"]> }) => (
  <button
    className="group-toggle nodrag nopan"
    title={group.collapsed ? `Expand: show the ${group.hides} components inside` : "Collapse into one node"}
    onClick={(e) => {
      e.stopPropagation();
      group.toggle();
    }}
  >
    {group.collapsed ? `▸ ${group.hides}` : "▾"}
  </button>
);

const ComponentNode = memo(({ data }: NodeProps<RFNode<NodeData>>) => {
  const c = data.comp;
  const score = Math.max(0, Math.min(1, data.score || 0));
  return (
    <div
      className={`node ${data.changed ? "changed" : "quiet"} ${statusClass(c)} ${data.dim ? "dim" : ""} ${data.selected ? "sel" : ""} ${data.group?.collapsed ? "collapsed" : ""}`}
      style={{ ["--score" as string]: score }}
    >
      <Handles />
      <div className="node-head">
        <span className="node-title" title={c.name}>
          {data.label}
        </span>
        {c.status && <span className={`tag ${statusClass(c)}`}>{c.status === "added" ? "new" : c.status}</span>}
        {c.layer && <span className="layer">{c.layer}</span>}
        {data.group && <GroupToggle group={data.group} />}
      </div>
      <div className="node-sub">
        <Badges counts={data.counts} />
        {!data.changed && <span className="muted">unchanged</span>}
      </div>
      {data.progress && data.progress.total > 0 && (
        <div className="node-progress" title={`${data.progress.done} of ${data.progress.total} reviewed`}>
          <span style={{ width: `${(100 * data.progress.done) / data.progress.total}%` }} />
        </div>
      )}
    </div>
  );
});

const GroupNode = memo(({ data }: NodeProps<RFNode<NodeData>>) => {
  const c = data.comp;
  return (
    <div className={`group ${statusClass(c)} ${data.dim ? "dim" : ""} ${data.selected ? "sel" : ""}`}>
      <Handles />
      <div className="group-title" title={c.name}>
        {data.group && <GroupToggle group={data.group} />}
        <span>{data.label}</span>
        <Badges counts={data.counts} />
        {c.status && <span className={`tag ${statusClass(c)}`}>{c.status === "added" ? "new" : c.status}</span>}
      </div>
    </div>
  );
});

const ExternalNode = memo(({ data }: NodeProps<RFNode<NodeData>>) => {
  const ext = data.ext;
  const label = !ext ? null : ext.change === "bumped" ? `${ext.from} → ${ext.to}` : ext.change === "added" ? `new ${ext.to ?? ""}` : "removed";
  return (
    <div className={`node ext ${ext ? `ext-${ext.change}` : "quiet"} ${data.dim ? "dim" : ""} ${data.selected ? "sel" : ""}`}>
      <Handles />
      <span className="node-title" title={data.comp.name}>
        {data.label}
      </span>
      {label && <span className="badge ext-badge">{label}</span>}
    </div>
  );
});

const nodeTypes = { component: ComponentNode, componentGroup: GroupNode, external: ExternalNode };

interface Props {
  index: Index;
  graph: MapGraph;
  focus: Focus;
  setFocus: (f: Focus) => void;
  showUnchanged: boolean;
  toggleGroup: (id: string) => void;
}

export function MapView(props: Props) {
  return (
    <ReactFlowProvider>
      <Flow {...props} />
    </ReactFlowProvider>
  );
}

function Flow({ index, graph, focus, setFocus, showUnchanged, toggleGroup }: Props) {
  const [placed, setPlaced] = useState<Map<string, Placed> | null>(null);
  const { fitBounds } = useReactFlow();
  const layoutKey = [...graph.nodes].sort().join("|");

  useEffect(() => {
    let live = true;
    // Only edges that changed shape the layout. Unchanged edges in a real app connect almost
    // everything to the model and core modules, and spread the map out until it's unreadable.
    layout(index, graph.nodes, graph.edges.filter((e) => e.status !== "unchanged")).then((p) => {
      if (!live) return;
      setPlaced(p);
      // Fit to the layout itself: React Flow may not have the new nodes yet, and it skips the
      // ones it hasn't rendered.
      const top = [...p.values()].filter((n) => !n.parent);
      if (top.length === 0) return;
      const x = Math.min(...top.map((n) => n.x));
      const y = Math.min(...top.map((n) => n.y));
      const width = Math.max(...top.map((n) => n.x + n.width)) - x;
      const height = Math.max(...top.map((n) => n.y + n.height)) - y;
      requestAnimationFrame(() => fitBounds({ x, y, width, height }, { padding: 0.12, duration: 0 }));
    });
    return () => {
      live = false;
    };
  }, [index, layoutKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const rel = useMemo(() => related(index, graph.edges, focus), [index, graph.edges, focus]);
  const { reviewed } = useReview();
  const progress = useMemo(() => {
    const out = new Map<string, { done: number; total: number }>();
    for (const id of graph.nodes) {
      const inside = graph.collapsed.has(id) ? index.model.components.filter((c) => within(index, c.id, id)).map((c) => c.id) : [id];
      const shown = inside.flatMap((c) => componentEntities(index, c).shown);
      out.set(id, { done: shown.filter((e) => reviewed[e.id]).length, total: shown.length });
    }
    return out;
  }, [index, graph, reviewed]);

  const nodes = useMemo<RFNode<NodeData>[]>(() => {
    if (!placed) return [];
    // React Flow needs parents before their children.
    const depth = (p: Placed): number => (p.parent ? 1 + depth(placed.get(p.parent)!) : 0);
    return [...placed.values()]
      .sort((a, b) => depth(a) - depth(b))
      .map((p) => {
        const comp = index.components.get(p.id)!;
        const hides = graph.collapsed.get(p.id);
        const type = p.isGroup ? "componentGroup" : comp.kind === "external" ? "external" : "component";
        const roll = hides ? rollup(index, p.id) : undefined;
        return {
          id: p.id,
          type,
          position: { x: p.x, y: p.y },
          parentId: p.parent,
          draggable: false,
          connectable: false,
          zIndex: p.isGroup ? 0 : 3, // above edges (2), so a tap on a node never lands on an edge passing under it
          // Known sizes, so fitting and culling work before React Flow has measured a node.
          width: p.width,
          height: p.height,
          data: {
            comp,
            label: shortName(index, comp),
            ext: externalChangeOf(index, comp),
            changed: roll ? roll.changed : isChanged(index, comp),
            dim: !!rel && !rel.nodes.has(p.id),
            selected: focus?.type === "component" && focus.id === p.id,
            progress: progress.get(p.id),
            counts: roll ?? comp,
            score: roll ? roll.changeScore : comp.changeScore,
            group: p.isGroup || hides ? { collapsed: !!hides, hides: hides ?? 0, toggle: () => toggleGroup(p.id) } : undefined,
          },
        };
      });
  }, [placed, index, graph, rel, focus, progress, toggleGroup]);

  const edges = useMemo<RFEdge[]>(() => {
    if (!placed) return [];
    return graph.edges
      .filter((e) => placed.has(e.from) && placed.has(e.to))
      .filter((e) => showUnchanged || e.status !== "unchanged" || rel?.edges.has(e.key))
      .map((e) => {
        const lit = !rel || rel.edges.has(e.key);
        const color = !lit ? DIMMED : e.status === "unchanged" && !rel ? QUIET_UNCHANGED : EDGE_COLORS[e.status];
        const selected = (focus?.type === "edge" && focus.key === e.key) || (focus?.type === "bundle" && e.bundle && focus.from === e.from && focus.to === e.to);
        const weight = 1 + Math.min(3, Math.log2(1 + e.refCount) / 2);
        return {
          id: e.key,
          source: e.from,
          target: e.to,
          zIndex: 2,
          interactionWidth: 18,
          className: `edge-${e.status}${e.bundle ? " edge-bundle" : ""}`,
          markerEnd: { type: MarkerType.ArrowClosed, color, width: 16, height: 16 },
          style: {
            stroke: color,
            strokeWidth: selected ? weight + 2 : weight,
            strokeDasharray: e.status === "removed" ? "6 4" : undefined,
          },
        };
      });
  }, [placed, graph.edges, rel, focus, showUnchanged]);

  const bundles = useMemo(() => new Map(graph.edges.filter((e) => e.bundle).map((e) => [e.key, e])), [graph.edges]);

  return (
    <ReactFlow
      nodes={nodes}
      edges={edges}
      nodeTypes={nodeTypes}
      onNodeClick={(_, n) => setFocus({ type: "component", id: n.id })}
      onEdgeClick={(_, e) => {
        const b = bundles.get(e.id);
        setFocus(b ? { type: "bundle", from: b.from, to: b.to } : { type: "edge", key: e.id });
      }}
      onPaneClick={() => setFocus(null)}
      nodesDraggable={false}
      nodesConnectable={false}
      elementsSelectable={false}
      onlyRenderVisibleElements
      minZoom={0.1}
      proOptions={{ hideAttribution: true }}
      colorMode="system"
    >
      <Background gap={24} size={1} />
      <Controls showInteractive={false} />
    </ReactFlow>
  );
}
