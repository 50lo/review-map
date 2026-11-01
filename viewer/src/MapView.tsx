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
import { edgeKey, externalChangeOf, isChanged, related, shortName, type Focus, type Index, type Visible } from "./graph";
import { layout, type Placed } from "./layout";
import type { Component, ExternalDepChange } from "./types";

export const EDGE_COLORS: Record<string, string> = {
  added: "var(--added)",
  removed: "var(--removed)",
  changed: "var(--changed)",
  unchanged: "var(--unchanged)",
};

interface NodeData extends Record<string, unknown> {
  comp: Component;
  label: string;
  ext?: ExternalDepChange;
  changed: boolean;
  dim: boolean;
  selected: boolean;
}

const Handles = () => (
  <>
    <Handle type="target" position={Position.Top} isConnectable={false} />
    <Handle type="source" position={Position.Bottom} isConnectable={false} />
  </>
);

const statusClass = (c: Component) => (c.status === "added" ? "st-added" : c.status === "removed" ? "st-removed" : "");

const Badges = ({ c }: { c: Component }) =>
  c.changedEntities > 0 ? (
    <span className="badges">
      <span className="badge" title="Changed entities">
        {c.changedEntities} changed
      </span>
      {c.interfaceChanges > 0 && (
        <span className="badge iface" title="Interface changes">
          {c.interfaceChanges} interface
        </span>
      )}
    </span>
  ) : null;

const ComponentNode = memo(({ data }: NodeProps<RFNode<NodeData>>) => {
  const c = data.comp;
  const score = Math.max(0, Math.min(1, c.changeScore || 0));
  return (
    <div
      className={`node ${data.changed ? "changed" : "quiet"} ${statusClass(c)} ${data.dim ? "dim" : ""} ${data.selected ? "sel" : ""}`}
      style={{ ["--score" as string]: score }}
    >
      <Handles />
      <div className="node-head">
        <span className="node-title" title={c.name}>
          {data.label}
        </span>
        {c.status && <span className={`tag ${statusClass(c)}`}>{c.status === "added" ? "new" : c.status}</span>}
        {c.layer && <span className="layer">{c.layer}</span>}
      </div>
      <div className="node-sub">
        <Badges c={c} />
        {!data.changed && <span className="muted">unchanged</span>}
      </div>
    </div>
  );
});

const GroupNode = memo(({ data }: NodeProps<RFNode<NodeData>>) => {
  const c = data.comp;
  return (
    <div className={`group ${statusClass(c)} ${data.dim ? "dim" : ""} ${data.selected ? "sel" : ""}`}>
      <Handles />
      <div className="group-title" title={c.name}>
        <span>{data.label}</span>
        <Badges c={c} />
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
  vis: Visible;
  focus: Focus;
  setFocus: (f: Focus) => void;
  showUnchanged: boolean;
}

export function MapView(props: Props) {
  return (
    <ReactFlowProvider>
      <Flow {...props} />
    </ReactFlowProvider>
  );
}

function Flow({ index, vis, focus, setFocus, showUnchanged }: Props) {
  const [placed, setPlaced] = useState<Map<string, Placed> | null>(null);
  const { fitView } = useReactFlow();
  const layoutKey = [...vis.nodes].sort().join("|");

  useEffect(() => {
    let live = true;
    // Only edges that changed shape the layout. Unchanged edges in a real app connect almost
    // everything to the model and core modules, and spread the map out until it's unreadable.
    layout(index, vis.nodes, vis.edges.filter((e) => e.status !== "unchanged")).then((p) => {
      if (!live) return;
      setPlaced(p);
      requestAnimationFrame(() => fitView({ padding: 0.12, duration: 0 }));
    });
    return () => {
      live = false;
    };
  }, [index, layoutKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const rel = useMemo(() => related(index, vis.edges, focus), [index, vis.edges, focus]);

  const nodes = useMemo<RFNode<NodeData>[]>(() => {
    if (!placed) return [];
    // React Flow needs parents before their children.
    const depth = (p: Placed): number => (p.parent ? 1 + depth(placed.get(p.parent)!) : 0);
    return [...placed.values()]
      .sort((a, b) => depth(a) - depth(b))
      .map((p) => {
        const comp = index.components.get(p.id)!;
        const type = p.isGroup ? "componentGroup" : comp.kind === "external" ? "external" : "component";
        return {
          id: p.id,
          type,
          position: { x: p.x, y: p.y },
          parentId: p.parent,
          draggable: false,
          connectable: false,
          zIndex: p.isGroup ? 0 : 1,
          style: { width: p.width, height: p.height },
          data: {
            comp,
            label: shortName(index, comp),
            ext: externalChangeOf(index, comp),
            changed: isChanged(index, comp),
            dim: !!rel && !rel.nodes.has(p.id),
            selected: focus?.type === "component" && focus.id === p.id,
          },
        };
      });
  }, [placed, index, rel, focus]);

  const edges = useMemo<RFEdge[]>(() => {
    if (!placed) return [];
    return vis.edges
      .filter((e) => placed.has(e.from) && placed.has(e.to))
      .filter((e) => showUnchanged || e.status !== "unchanged" || rel?.edges.has(edgeKey(e)))
      .map((e) => {
        const key = edgeKey(e);
        const color = EDGE_COLORS[e.status];
        const lit = !rel || rel.edges.has(key);
        const selected = focus?.type === "edge" && focus.key === key;
        const weight = 1 + Math.min(3, Math.log2(1 + (e.refCount ?? e.refs.length)) / 2);
        return {
          id: key,
          source: e.from,
          target: e.to,
          zIndex: 2,
          interactionWidth: 18,
          className: `edge-${e.status}`,
          markerEnd: { type: MarkerType.ArrowClosed, color, width: 16, height: 16 },
          style: {
            stroke: color,
            strokeWidth: selected ? weight + 2 : weight,
            strokeDasharray: e.status === "removed" ? "6 4" : undefined,
            opacity: lit ? (e.status === "unchanged" ? 0.45 : 1) : 0.08,
          },
        };
      });
  }, [placed, vis.edges, rel, focus, showUnchanged]);

  return (
    <ReactFlow
      nodes={nodes}
      edges={edges}
      nodeTypes={nodeTypes}
      onNodeClick={(_, n) => setFocus({ type: "component", id: n.id })}
      onEdgeClick={(_, e) => setFocus({ type: "edge", key: e.id })}
      onPaneClick={() => setFocus(null)}
      nodesDraggable={false}
      nodesConnectable={false}
      elementsSelectable={false}
      minZoom={0.1}
      proOptions={{ hideAttribution: true }}
      colorMode="system"
    >
      <Background gap={24} size={1} />
      <Controls showInteractive={false} />
    </ReactFlow>
  );
}
