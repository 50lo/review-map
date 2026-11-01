import { useState, type ReactNode } from "react";
import {
  componentEdges,
  componentEntities,
  edgeKey,
  externalChangeOf,
  startHere,
  type Focus,
  type Index,
  type StartItem,
} from "./graph";
import type { Component, Edge, Entity } from "./types";
import { ChangeTag, Chips, Signature, StatusDot } from "./ui";

interface Props {
  index: Index;
  focus: Focus;
  setFocus: (f: Focus) => void;
}

export function Sidebar({ index, focus, setFocus }: Props) {
  let body: ReactNode;
  if (focus?.type === "component" && index.components.has(focus.id)) {
    body = <ComponentPanel index={index} c={index.components.get(focus.id)!} setFocus={setFocus} />;
  } else if (focus?.type === "edge") {
    const e = index.model.edges.find((x) => edgeKey(x) === focus.key);
    body = e ? <EdgePanel index={index} e={e} setFocus={setFocus} /> : <Overview index={index} setFocus={setFocus} />;
  } else {
    body = <Overview index={index} setFocus={setFocus} />;
  }
  return <aside className="sidebar">{body}</aside>;
}

const Name = ({ index, id, setFocus }: { index: Index; id: string; setFocus: Props["setFocus"] }) => (
  <button className="link" onClick={() => setFocus({ type: "component", id })}>
    {index.components.get(id)?.name ?? id}
  </button>
);


// ---------------------------------------------------------------------------

function Overview({ index, setFocus }: { index: Index; setFocus: Props["setFocus"] }) {
  const { model } = index;
  const items = startHere(index);
  const changedComponents = model.components.filter((c) => c.kind !== "external" && c.changedEntities > 0).length;
  const byStatus = (s: Edge["status"]) => model.edges.filter((e) => e.status === s).length;
  const [showWarnings, setShowWarnings] = useState(false);
  return (
    <>
      <section>
        <h2>Start here</h2>
        {items.length === 0 && <p className="muted">No changes that need review.</p>}
        {items[0]?.source === "flags" && (
          <p className="muted small">Ranked by contract flags until the analyzer scores risk regions.</p>
        )}
        <ol className="start">
          {items.map((it) => (
            <StartRow key={it.id} index={index} it={it} setFocus={setFocus} />
          ))}
        </ol>
      </section>
      <section>
        <h2>This change</h2>
        <ul className="facts">
          <li>
            {changedComponents} component{changedComponents === 1 ? "" : "s"} changed, {model.entities.filter((e) => e.change !== "cosmetic").length} entities
          </li>
          <li>
            <StatusDot status="added" /> {byStatus("added")} added, <StatusDot status="removed" /> {byStatus("removed")} removed,{" "}
            <StatusDot status="changed" /> {byStatus("changed")} changed dependencies
          </li>
          {model.externalDeps.map((d) => (
            <li key={d.name}>
              <button className="link" onClick={() => setFocus({ type: "component", id: `ext:${d.name}` })}>
                {d.name}
              </button>{" "}
              {d.change === "bumped" ? `${d.from} → ${d.to}` : d.change}
            </li>
          ))}
        </ul>
      </section>
      <section>
        <h2>Legend</h2>
        <ul className="legend">
          <li>
            <span className="swatch added" /> added dependency
          </li>
          <li>
            <span className="swatch removed" /> removed dependency
          </li>
          <li>
            <span className="swatch changed" /> changed: different symbols referenced
          </li>
          <li>
            <span className="swatch unchanged" /> unchanged
          </li>
        </ul>
        <p className="muted small">Arrows point from the code that uses to the code it uses. Stronger tint means a larger change.</p>
      </section>
      {model.warnings.length > 0 && (
        <section>
          <button className="link" onClick={() => setShowWarnings(!showWarnings)}>
            {model.warnings.length} analyzer warning{model.warnings.length === 1 ? "" : "s"}
          </button>
          {showWarnings && (
            <ul className="warnings small">
              {model.warnings.map((w, i) => (
                <li key={i}>
                  <span className="muted">{w.kind}</span> {w.message}
                  {w.file && (
                    <span className="muted">
                      {" "}
                      {w.file}
                      {w.line ? `:${w.line}` : ""}
                    </span>
                  )}
                </li>
              ))}
            </ul>
          )}
        </section>
      )}
    </>
  );
}

function StartRow({ index, it, setFocus }: { index: Index; it: StartItem; setFocus: Props["setFocus"] }) {
  const comp = index.components.get(it.entity.component);
  return (
    <li>
      <button className="row" onClick={() => setFocus({ type: "entity", id: it.entity.id })}>
        <span className="row-main">
          <span className="kind">{it.entity.kind}</span> <span className="qname">{it.entity.qualifiedName}</span>
          {it.members.length > 0 && <span className="muted"> +{it.members.length} members</span>}
        </span>
        <span className="row-sub muted">
          {comp?.name ?? it.entity.component} · {it.entity.change}
          {it.entity.isInterface ? " · interface" : ""}
        </span>
        <Chips flags={it.reasons.filter((r) => r !== it.entity.change)} />
      </button>
    </li>
  );
}

// ---------------------------------------------------------------------------

function ComponentPanel({ index, c, setFocus }: { index: Index; c: Component; setFocus: Props["setFocus"] }) {
  const { shown, cosmetic, lowRisk } = componentEntities(index, c.id);
  const edges = componentEdges(index.model, c.id);
  const ext = externalChangeOf(index, c);
  const children = index.children.get(c.id) ?? [];
  return (
    <>
      <section>
        <h2 className="title">{c.name}</h2>
        {c.kind !== "external" && (
          <button className="btn primary open-iface" onClick={() => setFocus({ type: "interface", id: c.id })}>
            Open interface view ›
          </button>
        )}
        <p className="muted small">
          {[kindLabel(c.kind), c.module && c.module !== c.name ? `module ${c.module}` : null, c.layer, c.isTest ? "tests" : null, c.status]
            .filter(Boolean)
            .join(" · ")}
        </p>
        {c.paths.length > 0 && <p className="small mono">{c.paths.join(", ")}</p>}
        {c.parent && (
          <p className="small">
            Part of <Name index={index} id={c.parent} setFocus={setFocus} />
          </p>
        )}
        {children.length > 0 && (
          <p className="small">
            Split into{" "}
            {children.map((id, i) => (
              <span key={id}>
                {i > 0 && ", "}
                <Name index={index} id={id} setFocus={setFocus} />
              </span>
            ))}
          </p>
        )}
        {ext && <p>{ext.change === "bumped" ? `Version ${ext.from} → ${ext.to}` : `Package ${ext.change}${ext.to ? ` at ${ext.to}` : ""}`}</p>}
      </section>
      {(shown.length > 0 || cosmetic + lowRisk > 0) && (
        <section>
          <h2>
            Changed entities <span className="muted">{shown.length}</span>
          </h2>
          <ul className="entities">
            {shown.map((e) => (
              <EntityRow key={e.id} e={e} setFocus={setFocus} />
            ))}
          </ul>
          {cosmetic + lowRisk > 0 && (
            <p className="muted small">
              {[cosmetic && `${cosmetic} cosmetic`, lowRisk && `${lowRisk} test or generated`].filter(Boolean).join(", ")} not shown
            </p>
          )}
        </section>
      )}
      <EdgeList title="Depends on" index={index} byStatus={edges.outgoing} other={(e) => e.to} setFocus={setFocus} />
      <EdgeList title="Used by" index={index} byStatus={edges.incoming} other={(e) => e.from} setFocus={setFocus} />
    </>
  );
}

const kindLabel = (k: string) =>
  ({ spmTarget: "SPM target", xcodeTarget: "Xcode target", folder: "folder", external: "external package" })[k] ?? k;

function EntityRow({ e, setFocus }: { e: Entity; setFocus: Props["setFocus"] }) {
  return (
    <li className={e.isInterface ? "iface" : ""}>
      <button className="entity-link" onClick={() => setFocus({ type: "entity", id: e.id })}>
        <span className="kind">{e.kind}</span> <span className="qname">{e.qualifiedName}</span> <ChangeTag change={e.change} />
        {e.isInterface && <span className="muted small"> interface</span>}
      </button>
      <Signature e={e} />
      <Chips flags={e.contractFlags} />
      {(e.usedBy?.length ?? 0) > 0 && <div className="muted small">used from {new Set(e.usedBy!.map((u) => u.component)).size} other component(s)</div>}
    </li>
  );
}

export function EdgeList({
  title,
  index,
  byStatus,
  other,
  setFocus,
}: {
  title: string;
  index: Index;
  byStatus: Record<Edge["status"], Edge[]>;
  other: (e: Edge) => string;
  setFocus: Props["setFocus"];
}) {
  const [open, setOpen] = useState(false);
  const notable = [...byStatus.added, ...byStatus.removed, ...byStatus.changed];
  const quiet = byStatus.unchanged;
  if (notable.length + quiet.length === 0) return null;
  const row = (e: Edge) => (
    <li key={edgeKey(e)}>
      <StatusDot status={e.status} />{" "}
      <button className="link" onClick={() => setFocus({ type: "edge", key: edgeKey(e) })}>
        {index.components.get(other(e))?.name ?? other(e)}
      </button>{" "}
      <span className="muted small">
        {e.status !== "unchanged" ? `${e.status}, ` : ""}
        {e.refCount ?? e.refs.length} ref{(e.refCount ?? e.refs.length) === 1 ? "" : "s"}
      </span>
    </li>
  );
  return (
    <section>
      <h2>{title}</h2>
      <ul className="edges">{notable.map(row)}</ul>
      {quiet.length > 0 && (
        <>
          <button className="link small" onClick={() => setOpen(!open)}>
            {open ? "Hide" : ""} {quiet.length} unchanged {quiet.length === 1 ? "dependency" : "dependencies"}
          </button>
          {open && <ul className="edges">{quiet.map(row)}</ul>}
        </>
      )}
    </section>
  );
}

// ---------------------------------------------------------------------------

function EdgePanel({ index, e, setFocus }: { index: Index; e: Edge; setFocus: Props["setFocus"] }) {
  const added = new Set(e.symbolsAdded ?? []);
  const removed = new Set(e.symbolsRemoved ?? []);
  const total = e.refCount ?? e.refs.length;
  const bySymbol = new Map<string, typeof e.refs>();
  for (const r of e.refs) bySymbol.set(r.symbol, [...(bySymbol.get(r.symbol) ?? []), r]);
  const symbolClass = (s: string) => (added.has(s) ? "sym-added" : removed.has(s) ? "sym-removed" : "");
  return (
    <>
      <section>
        <h2 className="title">
          <Name index={index} id={e.from} setFocus={setFocus} /> → <Name index={index} id={e.to} setFocus={setFocus} />
        </h2>
        <p>
          <StatusDot status={e.status} /> {e.status}
          {e.status === "changed" && ": the set of referenced symbols changed"}
        </p>
        {added.size > 0 && (
          <p className="small">
            Now references: <span className="sym-added mono">{[...added].join(", ")}</span>
          </p>
        )}
        {removed.size > 0 && (
          <p className="small">
            No longer references: <span className="sym-removed mono">{[...removed].join(", ")}</span>
          </p>
        )}
      </section>
      <section>
        <h2>
          References <span className="muted">{total}</span>
        </h2>
        {e.refs.length < total && <p className="muted small">Showing {e.refs.length} of {total}, changed symbols first.</p>}
        <ul className="refs">
          {[...bySymbol].map(([symbol, refs]) => (
            <li key={symbol}>
              <div className={`mono ${symbolClass(symbol)}`}>{symbol}</div>
              <ul>
                {refs.map((r, i) => (
                  <li key={i} className="small mono muted">
                    {r.line === 0 ? `${r.file} (manifest)` : `${r.file}:${r.line}`}
                    {r.side === "base" ? " · base" : ""}
                  </li>
                ))}
              </ul>
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}
