import { useState, type ReactNode } from "react";
import {
  bundleMembers,
  componentEdges,
  componentEntities,
  edgeKey,
  hiddenNeighbors,
  isGroupOf,
  externalChangeOf,
  isLowRisk,
  kindLabel,
  llmOf,
  riskTier,
  startHere,
  stepRegion,
  type Focus,
  type Index,
  type MapGraph,
  type StartItem,
  type Visible,
} from "./graph";
import { findingsForComponent, findingsForEdge, findingsOf } from "./findings";
import { FindingsSection } from "./FindingsSection";
import { notesMarkdown, useReview } from "./review";
import type { Component, Edge, ReviewItem } from "./types";
import { ChangeTag, Chips, RankingToggle, LLMSummary, ReviewedBox, Signature, StatusDot } from "./ui";

/** What the map shows, and the controls that change it. */
export interface MapControls {
  vis: Visible;
  graph: MapGraph;
  showTests: boolean;
  /** Components whose neighbors were added. */
  expanded: Set<string>;
  toggleNeighbors: (id: string) => void;
  toggleGroup: (id: string) => void;
}

interface Props {
  index: Index;
  focus: Focus;
  setFocus: (f: Focus) => void;
  setLLM: (on: boolean) => void;
  map: MapControls;
}

export function Sidebar({ index, focus, setFocus, setLLM, map }: Props) {
  let body: ReactNode;
  if (focus?.type === "component" && index.components.has(focus.id)) {
    body = <ComponentPanel index={index} c={index.components.get(focus.id)!} setFocus={setFocus} map={map} />;
  } else if (focus?.type === "edge") {
    const e = index.model.edges.find((x) => edgeKey(x) === focus.key);
    body = e ? <EdgePanel index={index} e={e} setFocus={setFocus} /> : <Overview index={index} setFocus={setFocus} setLLM={setLLM} />;
  } else if (focus?.type === "bundle" && index.components.has(focus.from) && index.components.has(focus.to)) {
    body = <BundlePanel index={index} from={focus.from} to={focus.to} setFocus={setFocus} map={map} />;
  } else {
    body = <Overview index={index} setFocus={setFocus} setLLM={setLLM} />;
  }
  return <aside className="sidebar">{body}</aside>;
}

const Name = ({ index, id, setFocus }: { index: Index; id: string; setFocus: Props["setFocus"] }) => (
  <button className="link" onClick={() => setFocus({ type: "component", id })}>
    {index.components.get(id)?.name ?? id}
  </button>
);


// ---------------------------------------------------------------------------

function Overview({ index, setFocus, setLLM }: { index: Index; setFocus: Props["setFocus"]; setLLM: Props["setLLM"] }) {
  const { model } = index;
  const items = startHere(index);
  const review = useReview();
  const changedComponents = model.components.filter((c) => c.kind !== "external" && c.changedEntities > 0).length;
  const byStatus = (s: Edge["status"]) => model.edges.filter((e) => e.status === s).length;
  const [showWarnings, setShowWarnings] = useState(false);
  const toReview = model.entities.filter((e) => !isLowRisk(index, e));
  const done = toReview.filter((e) => review.reviewed[e.id]).length;
  return (
    <>
      <ReviewSection index={index} setFocus={setFocus} />
      <section>
        <h2>Start here</h2>
        {index.hasLLM && <RankingToggle on={index.llm} setOn={setLLM} />}
        {index.llm && <LLMStatus index={index} />}
        {index.riskOrder.length > 0 && (
          <p className="small step-all">
            <button className="btn primary" onClick={() => setFocus(stepRegion(index, null, 1))}>
              Review {index.riskOrder.length} regions by risk ›
            </button>{" "}
            <span className="muted kbd-hint">or press j and k</span>
          </p>
        )}
        {items.length === 0 && <p className="muted">No changes that need review.</p>}
        {items[0]?.source === "flags" && <p className="muted small">Ranked by contract flags: this model has no risk regions.</p>}
        <ol className="start">
          {items.map((it) => (
            <StartRow key={it.id} index={index} it={it} reviewed={!!review.reviewed[it.entity.id]} setFocus={setFocus} />
          ))}
        </ol>
      </section>
      {toReview.length > 0 && (
        <section>
          <h2>Progress</h2>
          <div className="progress" title={`${done} of ${toReview.length} reviewed`}>
            <span style={{ width: `${(100 * done) / toReview.length}%` }} />
          </div>
          <p className="small muted">
            {done} of {toReview.length} entities reviewed
          </p>
        </section>
      )}
      <NotesSection index={index} setFocus={setFocus} />
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
          <li className="muted">
            {model.analyzer?.resolution === "index" ? "References resolved exactly from the build index" : "References matched by name"}
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

function StartRow({ index, it, reviewed, setFocus }: { index: Index; it: StartItem; reviewed: boolean; setFocus: Props["setFocus"] }) {
  const comp = index.components.get(it.entity.component);
  return (
    <li className={reviewed ? "is-reviewed" : ""}>
      <button className="row" onClick={() => setFocus(it.focus)}>
        <span className="row-main">
          {it.source === "regions" && <span className={`risk risk-${riskTier(it.score)}`}>{it.score.toFixed(2)}</span>}{" "}
          <span className="kind">{kindLabel(it.entity)}</span> <span className="qname">{it.entity.qualifiedName}</span>
          {it.members.length > 0 && <span className="muted"> +{it.members.length} members</span>}
          {reviewed && <span className="muted small"> · reviewed</span>}
        </span>
        <span className="row-sub muted">
          {comp?.name ?? it.entity.component} · {it.entity.change}
          {it.entity.isInterface ? " · interface" : ""}
          {it.regionCount > 1 ? ` · ${it.regionCount} regions` : ""}
        </span>
        <Chips flags={it.reasons.filter((r) => r !== it.entity.change).slice(0, 4)} />
      </button>
    </li>
  );
}

/** Which CLI annotated the model, and how many components kept deterministic scores. */
function LLMStatus({ index }: { index: Index }) {
  const run = index.model.llm!;
  const rejected = index.model.warnings.filter((w) => w.kind === "llm-rejected");
  const [open, setOpen] = useState(false);
  return (
    <div className="small muted llm-status">
      Scored by {run.command ? `${run.command}, standing in for ${run.tool}` : run.tool}
      {run.model ? ` (${run.model})` : ""}
      {run.reviewNotes ? " with REVIEW.md" : ""}.
      {run.failed > 0 && (
        <>
          {" "}
          <button className="link" onClick={() => setOpen(!open)}>
            {run.failed} batch{run.failed === 1 ? "" : "es"} kept deterministic scores
          </button>
          {open && (
            <ul className="warnings">
              {rejected.map((w, i) => (
                <li key={i}>{w.message}</li>
              ))}
            </ul>
          )}
        </>
      )}
    </div>
  );
}

/** The structural review's findings, most severe first. */
function ReviewSection({ index, setFocus }: { index: Index; setFocus: Props["setFocus"] }) {
  const findings = findingsOf(index);
  const run = index.model.llm;
  const hidden = !index.llm && (index.model.findings ?? []).some((f) => f.source === "llm");
  let note: string | undefined;
  if (findings.length === 0) note = "The structural checks found nothing.";
  if (hidden) note = "The LLM's findings are hidden while the LLM layer is off.";
  else if (index.llm && run?.review === "rejected") note = "The LLM's structural review was rejected; only the deterministic checks are shown.";
  return <FindingsSection index={index} title="Structural review" findings={findings} go={setFocus} note={note} />;
}

/** Notes on regions, each leading back to its region, and the Markdown export. */
function NotesSection({ index, setFocus }: { index: Index; setFocus: Props["setFocus"] }) {
  const review = useReview();
  const [copied, setCopied] = useState(false);
  const notes = Object.entries(review.notes).sort(([, a], [, b]) => a.file.localeCompare(b.file) || a.startLine - b.startLine);
  if (notes.length === 0) return null;
  const md = notesMarkdown(review.notes);
  const download = () => {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([md], { type: "text/markdown" }));
    a.download = "review-notes.md";
    a.click();
    URL.revokeObjectURL(a.href);
  };
  return (
    <section>
      <h2>
        Notes <span className="muted">{notes.length}</span>
      </h2>
      <ul className="notes-list">
        {notes.map(([id, n]) => (
          <li key={id}>
            <button className="link mono small" onClick={() => setFocus(index.regions.has(id) ? { type: "entity", id: n.entity, region: id } : { type: "location", side: n.side, file: n.file, line: n.startLine })}>
              {n.label}
            </button>
            <div className="small">{n.text}</div>
          </li>
        ))}
      </ul>
      <p className="small">
        <button
          className="btn"
          onClick={() =>
            navigator.clipboard?.writeText(md).then(
              () => setCopied(true),
              () => setCopied(false),
            )
          }
        >
          {copied ? "Copied" : "Copy as Markdown"}
        </button>{" "}
        <button className="btn" onClick={download}>
          Download .md
        </button>
      </p>
    </section>
  );
}

// ---------------------------------------------------------------------------

function ComponentPanel({ index, c, setFocus, map }: { index: Index; c: Component; setFocus: Props["setFocus"]; map: MapControls }) {
  const { shown, cosmetic, lowRisk } = componentEntities(index, c.id);
  const edges = componentEdges(index.model, c.id);
  const ext = externalChangeOf(index, c);
  const children = index.children.get(c.id) ?? [];
  const hidden = hiddenNeighbors(index, map.vis, c.id, map.showTests);
  const added = map.expanded.has(c.id);
  const isGroup = isGroupOf(index, map.vis, c.id);
  const findings = findingsForComponent(index, c.id, { inside: map.graph.collapsed.has(c.id) });
  return (
    <>
      <section>
        <h2 className="title">{c.name}</h2>
        {c.kind !== "external" && (
          <button className="btn primary open-iface" onClick={() => setFocus({ type: "interface", id: c.id })}>
            Open interface view ›
          </button>
        )}
        {(hidden.length > 0 || added || isGroup) && (
          <p className="small map-actions">
            {(hidden.length > 0 || added) && (
              <button className="btn" onClick={() => map.toggleNeighbors(c.id)}>
                {added ? "Hide added neighbors" : `Show ${hidden.length} more neighbor${hidden.length === 1 ? "" : "s"}`}
              </button>
            )}
            {isGroup && (
              <button className="btn" onClick={() => map.toggleGroup(c.id)}>
                {map.graph.collapsed.has(c.id) ? "Expand group" : "Collapse group"}
              </button>
            )}
          </p>
        )}
        <p className="muted small">
          {[componentKindLabel(c.kind), c.module && c.module !== c.name ? `module ${c.module}` : null, c.layer, c.isTest ? "tests" : null, c.status]
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
        {llmOf(index, c) && <LLMSummary text={llmOf(index, c)!.summary} />}
      </section>
      <FindingsSection index={index} title="Findings" findings={findings} go={setFocus} hideAnchor={(a) => a.component === c.id} />
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

const componentKindLabel = (k: string) =>
  ({
    spmTarget: "SPM target",
    xcodeTarget: "Xcode target",
    npmPackage: "npm package",
    tsconfig: "tsconfig project",
    goPackage: "Go package",
    folder: "folder",
    external: "external package",
  })[k] ?? k;

function EntityRow({ e, setFocus }: { e: ReviewItem; setFocus: Props["setFocus"] }) {
  return (
    <li className={`with-check ${e.isInterface ? "iface" : ""}`}>
      <ReviewedBox id={e.id} compact />
      <button className="entity-link" onClick={() => setFocus({ type: "entity", id: e.id })}>
        <span className="kind">{kindLabel(e)}</span> <span className="qname">{e.qualifiedName}</span> <ChangeTag change={e.change} />
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
  label,
  setFocus,
}: {
  title: string;
  index: Index;
  byStatus: Record<Edge["status"], Edge[]>;
  /** The component at the other end, named in each row. */
  other?: (e: Edge) => string;
  /** Or the whole row label. */
  label?: (e: Edge) => string;
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
        {label ? label(e) : (index.components.get(other!(e))?.name ?? other!(e))}
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
  const findings = findingsForEdge(index, e.from, e.to);
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
      <FindingsSection index={index} title="Findings" findings={findings} go={setFocus} hideAnchor={(a) => a.from === e.from && a.to === e.to} />
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

// ---------------------------------------------------------------------------

/** The edges behind one arrow into or out of a collapsed group. */
function BundlePanel({ index, from, to, setFocus, map }: { index: Index; from: string; to: string; setFocus: Props["setFocus"]; map: MapControls }) {
  const drawn = map.graph.edges.find((e) => e.bundle && e.from === from && e.to === to);
  const members = drawn?.members ?? bundleMembers(index, from, to);
  const byStatus = { added: [] as Edge[], removed: [] as Edge[], changed: [] as Edge[], unchanged: [] as Edge[] };
  for (const e of members) byStatus[e.status].push(e);
  const name = (id: string) => index.components.get(id)?.name ?? id;
  const findings = [...new Set(members.flatMap((e) => findingsForEdge(index, e.from, e.to)))];
  return (
    <>
      <section>
        <h2 className="title">
          <Name index={index} id={from} setFocus={setFocus} /> → <Name index={index} id={to} setFocus={setFocus} />
        </h2>
        <p className="small muted">
          {members.length} dependenc{members.length === 1 ? "y" : "ies"} between the components inside. Pick one to see its references; its group opens on the
          map.
        </p>
      </section>
      <FindingsSection index={index} title="Findings" findings={findings} go={setFocus} />
      <EdgeList title="Dependencies" index={index} byStatus={byStatus} label={(e) => `${name(e.from)} → ${name(e.to)}`} setFocus={setFocus} />
    </>
  );
}
