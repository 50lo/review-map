// Levels 2 and 3 of the viewer: a component's interface view, an entity's implementation view,
// and a plain code location.

import { useEffect, useMemo, useState } from "react";
import { CodeView, useSource, type CodeRegion } from "./CodeView";
import { lineChanges } from "./diff";
import { componentEdges, contextOf, flagLabel, kindLabel, llmOf, regionPosition, regionRisk, riskTier, stepRegion, type Index } from "./graph";
import {
  dependsOnTarget,
  findEntity,
  groupUsages,
  interfaceModel,
  lastName,
  membersOf,
  neighbors,
  symbolTargets,
  usedByTarget,
} from "./levels";
import type { Focus } from "./nav";
import { findingsForComponent, findingsForEntity } from "./findings";
import { FindingsSection } from "./FindingsSection";
import { EdgeList } from "./Sidebar";
import { canOpenInEditor, editorName, openInEditor } from "./source";
import { setNote, useReview } from "./review";
import type { ReviewItem, Region, Usage } from "./types";
import { ChangeTag, Chips, LLMSummary, ReviewedBox, Signature } from "./ui";

type Go = (f: Focus) => void;

const compName = (index: Index, id: string) => index.components.get(id)?.name ?? id;

// ---------------------------------------------------------------------------
// Level 2

export function InterfacePage({ index, id, go }: { index: Index; id: string; go: Go }) {
  const c = index.components.get(id);
  const m = useMemo(() => interfaceModel(index, id), [index, id]);
  const [showHidden, setShowHidden] = useState(false);
  if (!c) return <div className="page-inner muted">No component {id} in this change.</div>;
  const children = index.children.get(id) ?? [];
  const edges = componentEdges(index.model, id);
  const ifaceCount = m.groups.reduce((s, g) => s + g.entities.length, 0);
  return (
    <div className="page-inner">
      <header className="page-head">
        <div className="eyebrow">Component</div>
        <h1>{c.name}</h1>
        <p className="muted small">
          {[c.module && c.module !== c.name ? `module ${c.module}` : null, c.layer, c.isTest ? "tests" : null, c.status, c.paths.join(", ")]
            .filter(Boolean)
            .join(" · ")}
        </p>
        <p className="small">
          <button className="link" onClick={() => go({ type: "component", id })}>
            Show on map
          </button>
          {c.parent && (
            <>
              {" · part of "}
              <button className="link" onClick={() => go({ type: "interface", id: c.parent! })}>
                {compName(index, c.parent)}
              </button>
            </>
          )}
        </p>
        {llmOf(index, c) && <LLMSummary text={llmOf(index, c)!.summary} />}
      </header>

      <FindingsSection index={index} title="Findings" findings={findingsForComponent(index, id)} go={go} hideAnchor={(a) => a.component === id} />

      {children.length > 0 && (
        <section>
          <h2>Folders</h2>
          <ul className="plain">
            {children.map((cid) => {
              const ch = index.components.get(cid)!;
              return (
                <li key={cid}>
                  <button className="link" onClick={() => go({ type: "interface", id: cid })}>
                    {ch.name}
                  </button>{" "}
                  <span className="muted small">
                    {ch.changedEntities ? `${ch.changedEntities} changed, ${ch.interfaceChanges} interface` : "unchanged"}
                  </span>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      <section>
        <h2>
          Interface changes <span className="count">{ifaceCount}</span>
        </h2>
        {ifaceCount === 0 && <p className="muted">No changed declarations are used outside this component.</p>}
        {m.groups.map((g) => (
          <div key={g.title} className="kind-group">
            <h3>
              {g.title} <span className="count">{g.entities.length}</span>
            </h3>
            {g.entities.map((e) => (
              <EntityCard key={e.id} index={index} e={e} go={go} />
            ))}
          </div>
        ))}
      </section>

      {m.internal.length > 0 && (
        <section>
          <h2>
            Internal changes <span className="count">{m.internal.length}</span>
          </h2>
          <ul className="one-liners">
            {m.internal.map((e) => (
              <OneLiner key={e.id} e={e} go={go} />
            ))}
          </ul>
        </section>
      )}

      {m.hidden.length > 0 && (
        <section>
          <button className="link small" onClick={() => setShowHidden(!showHidden)}>
            {showHidden ? "Hide" : "Show"} {m.hidden.length} cosmetic, test, or generated change{m.hidden.length === 1 ? "" : "s"}
          </button>
          {showHidden && (
            <ul className="one-liners">
              {m.hidden.map((e) => (
                <OneLiner key={e.id} e={e} go={go} />
              ))}
            </ul>
          )}
        </section>
      )}

      <div className="page-edges">
        <EdgeList title="Depends on" index={index} byStatus={edges.outgoing} other={(e) => e.to} setFocus={go} />
        <EdgeList title="Used by" index={index} byStatus={edges.incoming} other={(e) => e.from} setFocus={go} />
      </div>
    </div>
  );
}

function EntityCard({ index, e, go }: { index: Index; e: ReviewItem; go: Go }) {
  return (
    <article className="card">
      <ReviewedBox id={e.id} compact />
      <button className="card-title" onClick={() => go({ type: "entity", id: e.id })}>
        <span className="kind">{kindLabel(e)}</span> <span className="qname">{e.qualifiedName}</span> <ChangeTag change={e.change} />
        <span className="chev">›</span>
      </button>
      <Signature e={e} />
      <Chips flags={e.contractFlags} />
      {llmOf(index, e) && <LLMSummary text={llmOf(index, e)!.summary} />}
      <Usages index={index} title="Used by" usages={e.usedBy ?? []} target={(u) => usedByTarget(index, u)} go={go} />
      <Usages index={index} title="Depends on" usages={e.dependsOn ?? []} target={(u) => dependsOnTarget(index, u)} go={go} />
    </article>
  );
}

const OneLiner = ({ e, id, go }: { e: ReviewItem; id?: string; go: Go }) => (
  <li className="with-check">
    <ReviewedBox id={id ?? e.id} compact />
    <button className="one-liner" onClick={() => go({ type: "entity", id: id ?? e.id })}>
      <span className="kind">{kindLabel(e)}</span> <span className="qname">{e.qualifiedName}</span> <ChangeTag change={e.change} />
      {e.contractFlags.length > 0 && <span className="muted small"> · {e.contractFlags.length} flag{e.contractFlags.length === 1 ? "" : "s"}</span>}
    </button>
  </li>
);

/**
 * References to or from other components, grouped by component. The first few show; the rest
 * fold into a count that opens them.
 */
function Usages({
  index,
  title,
  usages,
  target,
  go,
  limit = 4,
}: {
  index: Index;
  title: string;
  usages: Usage[];
  target: (u: Usage) => Focus;
  go: Go;
  limit?: number;
}) {
  const [open, setOpen] = useState(false);
  if (usages.length === 0) return null;
  const groups = groupUsages(usages, index);
  let shown = 0;
  return (
    <div className="usages">
      <span className="usages-title">
        {title} <span className="count">{usages.length}</span>
      </span>
      <ul>
        {groups.map((g) => {
          const take = open ? g.usages : g.usages.slice(0, Math.max(0, limit - shown));
          shown += take.length;
          if (take.length === 0) return null;
          return (
            <li key={g.component}>
              <button className="link comp" onClick={() => go({ type: "interface", id: g.component })}>
                {compName(index, g.component)}
              </button>
              {bySymbol(take).map((s) => (
                <div key={s.symbol} className="usage">
                  <button className="usage-sym mono" onClick={() => go(target(s.usages[0]))}>
                    {s.symbol}
                  </button>{" "}
                  <span className="muted small">
                    {s.usages[0].file.split("/").pop()}:
                    {s.usages.map((u, i) => (
                      <span key={i}>
                        {i > 0 && ", "}
                        <button className="line-link" onClick={() => go({ type: "location", side: "head", file: u.file, line: u.line })}>
                          {u.line}
                        </button>
                      </span>
                    ))}
                  </span>
                </div>
              ))}
            </li>
          );
        })}
      </ul>
      {!open && usages.length > shown && (
        <button className="link small" onClick={() => setOpen(true)}>
          {usages.length - shown} more in {groups.length} component{groups.length === 1 ? "" : "s"}
        </button>
      )}
    </div>
  );
}

/** Usages from the same declaration in the same file, as one row with several lines. */
function bySymbol(usages: Usage[]): Array<{ symbol: string; usages: Usage[] }> {
  const m = new Map<string, Usage[]>();
  for (const u of usages) {
    const k = `${u.symbol}\u0000${u.file}`;
    m.set(k, [...(m.get(k) ?? []), u]);
  }
  return [...m.values()].map((us) => ({ symbol: us[0].symbol, usages: us }));
}

// ---------------------------------------------------------------------------
// Level 3

function OpenButton({ file, line, compact }: { file: string; line: number; compact?: boolean }) {
  const [msg, setMsg] = useState<string | null>(null);
  if (!canOpenInEditor()) return null;
  const name = editorName()!;
  return (
    <span className="open-in">
      <button className={compact ? "link small" : "btn"} onClick={() => openInEditor(file, line).then(setMsg)} title={`${file}:${line} in your working copy`}>
        {compact ? name : `Open in ${name}`}
      </button>
      {msg && <span className="muted small"> {msg}</span>}
    </span>
  );
}

export function EntityPage({ index, id, region, go }: { index: Index; id: string; region?: string; go: Go }) {
  const e = index.entities.get(id);
  if (!e) return <div className="page-inner muted">No entity {id} in this change.</div>;
  return <EntityPageInner key={id} index={index} e={e} region={region} go={go} />;
}

const RELATION_LABEL: Record<string, string> = {
  definition: "definition",
  caller: "caller",
  conformer: "conformer",
  override: "override",
  state: "state",
};

function EntityPageInner({ index, e, region: focusRegion, go }: { index: Index; e: ReviewItem; region?: string; go: Go }) {
  const nb = neighbors(index, e);
  const parent = e.parent ? index.entities.get(e.parent) : undefined;
  const parentName = e.parent?.split("::").slice(1).join("::");
  const members = membersOf(index, e);
  const symbols = useMemo(() => symbolTargets(index, e), [index, e]);
  const isRemoved = e.change === "removed";
  const loc = e.location;
  const base = !isRemoved && e.change !== "added" ? e.baseLocation : undefined;
  const baseSrc = useSource("base", base?.file ?? "");
  const headSrc = useSource(loc.side, loc.file);
  const review = useReview();
  const [editing, setEditing] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);

  const own = useMemo(() => index.regionsByEntity.get(e.id) ?? [], [index, e.id]);
  const { shown: contexts, pruned } = useMemo(() => contextOf(index, e.id), [index, e.id]);

  // Removed lines inside the entity, as collapsed markers. Lines changed in place are marked only
  // when the analyzer gave no regions for the entity.
  const changes = useMemo(() => {
    if (!base || baseSrc.text === null || headSrc.text === null) return undefined;
    const b = baseSrc.text.split("\n").slice(base.startLine - 1, base.endLine);
    const h = headSrc.text.split("\n").slice(loc.startLine - 1, loc.endLine);
    const lc = lineChanges(b, h);
    // A removed region the line comparison placed elsewhere still gets its marker.
    for (const r of own) {
      if (r.kind !== "removed" || r.anchor === undefined) continue;
      const at = r.anchor - loc.startLine;
      if (!lc.removed.has(at)) lc.removed.set(at, baseSrc.text.split("\n").slice(r.startLine - 1, r.endLine));
    }
    return lc;
  }, [base, baseSrc.text, headSrc.text, loc, own]);

  const codeRegions = useMemo<CodeRegion[]>(
    () =>
      own.map((r) =>
        r.kind === "removed" && r.anchor !== undefined
          ? { id: r.id, kind: "removed", from: 0, to: 0, at: r.anchor - loc.startLine, focused: r.id === focusRegion }
          : { id: r.id, kind: "review", from: r.startLine - loc.startLine, to: r.endLine - loc.startLine, focused: r.id === focusRegion },
      ),
    [own, loc.startLine, focusRegion],
  );

  // Each context region shows once, after the first region it supports.
  const placement = useMemo(() => {
    const byIndex = new Map<number, { regions: Region[]; contexts: Region[]; pruned: Region[] }>();
    const slot = (i: number) => {
      if (!byIndex.has(i)) byIndex.set(i, { regions: [], contexts: [], pruned: [] });
      return byIndex.get(i)!;
    };
    const endOf = new Map(codeRegions.map((r) => [r.id, r.kind === "removed" ? r.at ?? -1 : r.to]));
    for (const r of own) slot(endOf.get(r.id) ?? loc.endLine - loc.startLine).regions.push(r);
    const last = loc.endLine - loc.startLine;
    const place = (c: Region) => {
      const ends = (c.supports ?? []).map((id) => endOf.get(id)).filter((x): x is number => x !== undefined);
      return slot(ends.length ? Math.min(...ends) : last);
    };
    for (const c of contexts) place(c).contexts.push(c);
    for (const c of pruned) place(c).pruned.push(c);
    return byIndex;
  }, [own, contexts, pruned, codeRegions, loc]);

  useEffect(() => {
    if (!loaded || !focusRegion) return;
    document.querySelector(`[data-region="${CSS.escape(focusRegion)}"]`)?.scrollIntoView({ block: "center" });
  }, [loaded, focusRegion]);

  const firstRegion = own.find((r) => r.kind === "review");
  const fallbackChanged = own.length === 0 ? changes?.changed : undefined;
  const firstChanged = fallbackChanged ? fallbackChanged.findIndex(Boolean) : firstRegion ? firstRegion.startLine - loc.startLine : -1;
  const removedCount = changes ? [...changes.removed.values()].reduce((s, l) => s + l.length, 0) : 0;
  const pos = regionPosition(index, focusRegion ? { type: "entity", id: e.id, region: focusRegion } : null);
  const total = index.riskOrder.length;
  const label = e.qualifiedName;

  const regionHead = (cr: CodeRegion) => {
    const r = index.regions.get(cr.id);
    if (!r) return null;
    const risk = regionRisk(index, r);
    const ai = llmOf(index, r);
    const scoredByLLM = ai?.risk !== undefined;
    return (
      <div className="rh">
        <span
          className={`risk risk-${riskTier(risk)} ${scoredByLLM ? "risk-llm" : ""}`}
          title={scoredByLLM ? `LLM risk ${risk.toFixed(2)}, deterministic ${r.risk.toFixed(2)}` : `risk ${risk.toFixed(2)}`}
        >
          {risk.toFixed(2)}
        </span>
        <span className="rh-reasons">
          {r.reasons.map((x) => (
            <span key={x} className="reason">
              {flagLabel(x)}
            </span>
          ))}
        </span>
        <span className="rh-actions">
          {!review.notes[r.id] && editing !== r.id && (
            <button className="link small" onClick={() => setEditing(r.id)}>
              Note
            </button>
          )}
          {r.side === "head" && <OpenButton file={r.file} line={r.startLine} compact />}
        </span>
      </div>
    );
  };

  const after = (i: number) => {
    const p = placement.get(i);
    if (!p) return null;
    return (
      <>
        {p.regions.map((r) =>
          editing === r.id || review.notes[r.id] ? (
            <NoteBox key={r.id} r={r} label={label} editing={editing === r.id} setEditing={setEditing} />
          ) : null,
        )}
        {(p.contexts.length > 0 || p.pruned.length > 0) && (
          <div className="ctx-list">
            {p.contexts.map((c) => (
              <ContextSnippet key={c.id} index={index} e={e} c={c} go={go} />
            ))}
            {p.pruned.length > 0 && <PrunedContext index={index} e={e} items={p.pruned} go={go} />}
          </div>
        )}
      </>
    );
  };

  return (
    <div className="page-inner">
      <header className="page-head">
        <div className="eyebrow">
          {kindLabel(e)} in{" "}
          <button className="link" onClick={() => go({ type: "interface", id: e.component })}>
            {compName(index, e.component)}
          </button>
          {parentName && (
            <>
              {" · "}
              {parent ? (
                <button className="link" onClick={() => go({ type: "entity", id: parent.id })}>
                  {parent.qualifiedName}
                </button>
              ) : (
                <span>{parentName}</span>
              )}
            </>
          )}
        </div>
        <h1 className="mono-title">{e.qualifiedName}</h1>
        <p className="tags">
          <ReviewedBox id={e.id} />
          <ChangeTag change={e.change} />
          {(e.changes ?? []).filter((c) => c !== e.change).map((c) => (
            <ChangeTag key={c} change={c} />
          ))}
          {e.isInterface && <span className="iface-tag">interface</span>}
          {e.tags?.map((t) => (
            <span key={t} className="muted small">
              {t}
            </span>
          ))}
        </p>
        <Signature e={e} />
        <Chips flags={e.contractFlags} />
        {llmOf(index, e) && <LLMSummary text={llmOf(index, e)!.summary} />}
        <div className="page-actions">
          {total > 0 && (
            <span className="stepper" title="Regions across the change, highest risk first (keys j and k)">
              <button className="btn" disabled={pos === 1} onClick={() => go(stepRegion(index, { type: "entity", id: e.id, region: focusRegion }, -1))}>
                ‹
              </button>
              <span className="muted small">
                {pos ? `Region ${pos} of ${total}` : `${total} regions`} by {index.llm ? "LLM " : ""}risk
              </span>
              <button className="btn" disabled={pos === total} onClick={() => go(stepRegion(index, { type: "entity", id: e.id, region: focusRegion }, 1))}>
                ›
              </button>
            </span>
          )}
          <span className="stepper" title={`Entities in ${compName(index, e.component)}, in interface view order`}>
            <button className="btn" disabled={!nb.prev} onClick={() => nb.prev && go({ type: "entity", id: nb.prev.id })}>
              ‹
            </button>
            <span className="muted small">
              Review item {nb.position} of {nb.total}
            </span>
            <button className="btn" disabled={!nb.next} onClick={() => nb.next && go({ type: "entity", id: nb.next.id })}>
              ›
            </button>
          </span>
          {!isRemoved && loc.side === "head" && <OpenButton file={loc.file} line={loc.startLine + Math.max(0, firstChanged)} />}
        </div>
      </header>

      <FindingsSection index={index} title="Findings" findings={findingsForEntity(index, e.id)} go={go} hideAnchor={(a) => a.entity === e.id} />

      {(e.similar?.length ?? 0) > 0 && (
        <section>
          <h2>
            Similar existing declarations <span className="count">{e.similar!.length}</span>
          </h2>
          <p className="muted small">Names close to this new one. Check that it doesn't duplicate one of them.</p>
          <ul className="plain">
            {e.similar!.map((u) => (
              <li key={`${u.file}:${u.line}`}>
                <button className="link mono" onClick={() => go({ type: "location", side: "head", file: u.file, line: u.line })}>
                  {u.symbol}
                </button>{" "}
                <span className="muted small">
                  {compName(index, u.component)} · {u.file}:{u.line}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {members.length > 0 && (
        <section>
          <h2>
            Changed members <span className="count">{members.length}</span>
          </h2>
          <ul className="one-liners">
            {members.map((m) => (
              <OneLiner key={m.id} e={{ ...m, qualifiedName: lastName(m.qualifiedName) }} id={m.id} go={go} />
            ))}
          </ul>
        </section>
      )}

      <section>
        <h2>{isRemoved ? "Removed code" : "Code"}</h2>
        <p className="muted small mono path">
          {loc.file}:{loc.startLine}
          {loc.endLine > loc.startLine ? `–${loc.endLine}` : ""}
          {loc.side === "base" ? " at base" : ""}
        </p>
        {isRemoved && <p className="muted small">This declaration no longer exists at head. Its code at base:</p>}
        {own.length > 0 ? (
          <p className="muted small">
            <span className="mark-sample" /> {own.length} region{own.length === 1 ? "" : "s"} to review
            {contexts.length > 0 ? `, ${contexts.length} context snippet${contexts.length === 1 ? "" : "s"}` : ""}
            {pruned.length > 0 ? ` (${pruned.length} left out by the LLM)` : ""}
            {removedCount > 0 ? `, ${removedCount} removed line${removedCount === 1 ? "" : "s"}` : ""}. Unchanged code is folded.
          </p>
        ) : (
          fallbackChanged && (
            <p className="muted small">
              <span className="mark-sample" /> {fallbackChanged.filter(Boolean).length} changed lines. Unchanged code is folded.
            </p>
          )
        )}
        <CodeView
          side={loc.side}
          file={loc.file}
          startLine={loc.startLine}
          endLine={loc.endLine}
          changed={fallbackChanged}
          removed={changes?.removed}
          removedStyle={isRemoved}
          symbols={symbols}
          go={go}
          regions={codeRegions}
          regionHead={regionHead}
          after={after}
          onLines={(l) => setLoaded(!!l)}
        />
      </section>

      {(e.usedBy?.length ?? 0) > 0 && (
        <section>
          <h2>Callers and users in other components</h2>
          <Usages index={index} title="Used by" usages={e.usedBy!} target={(u) => usedByTarget(index, u)} go={go} limit={12} />
        </section>
      )}
      {(e.dependsOn?.length ?? 0) > 0 && (
        <section>
          <h2>Uses from other components</h2>
          <Usages index={index} title="Depends on" usages={e.dependsOn!} target={(u) => dependsOnTarget(index, u)} go={go} limit={12} />
        </section>
      )}
    </div>
  );
}

/** Unchanged code that explains a region, as a one-line label that expands to the lines that matter. */
function ContextSnippet({ index, e, c, go }: { index: Index; e: ReviewItem; c: Region; go: Go }) {
  const [open, setOpen] = useState(false);
  const where = c.component && c.component !== e.component ? ` in ${compName(index, c.component)}` : "";
  const target = c.component ? findEntity(index, c.component, c.reasons[0]) : undefined;
  const keep = c.lines?.map((l) => l - c.startLine);
  return (
    <div className={`ctx ${open ? "open" : ""}`}>
      <button className="ctx-label" onClick={() => setOpen(!open)}>
        <span className="ctx-chev">{open ? "▾" : "▸"}</span>
        <span className="ctx-rel">
          {RELATION_LABEL[c.relation ?? ""] ?? c.relation}
          {where}
        </span>{" "}
        <span className="mono ctx-name">{c.reasons[0]}</span>{" "}
        <span className="muted small">
          {c.file.split("/").pop()}:{c.startLine}
        </span>
      </button>
      {open && (
        <div className="ctx-body">
          <CodeView side={c.side} file={c.file} startLine={c.startLine} endLine={c.endLine} keep={keep} foldLabel="lines" go={go} symbols={symbolTargets(index)} />
          <button
            className="link small"
            onClick={() => go(target ? { type: "entity", id: target.id } : { type: "location", side: c.side, file: c.file, line: c.lines?.[1] ?? c.startLine })}
          >
            {target ? "Open its changes ›" : "Open in file ›"}
          </button>
        </div>
      )}
    </div>
  );
}

/** Context the LLM left out, folded into a count that opens it. */
function PrunedContext({ index, e, items, go }: { index: Index; e: ReviewItem; items: Region[]; go: Go }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button className="link small ctx-pruned" onClick={() => setOpen(!open)}>
        {open ? "Hide" : "Show"} {items.length} context snippet{items.length === 1 ? "" : "s"} left out by the LLM
      </button>
      {open && items.map((c) => <ContextSnippet key={c.id} index={index} e={e} c={c} go={go} />)}
    </>
  );
}

function NoteBox({ r, label, editing, setEditing }: { r: Region; label: string; editing: boolean; setEditing: (id: string | null) => void }) {
  const review = useReview();
  const note = review.notes[r.id];
  const [text, setText] = useState(note?.text ?? "");
  if (!editing && note) {
    return (
      <div className="note">
        <div className="note-text">{note.text}</div>
        <span className="note-actions">
          <button className="link small" onClick={() => { setText(note.text); setEditing(r.id); }}>
            Edit
          </button>
          <button className="link small" onClick={() => setNote(r, label, null)}>
            Delete
          </button>
        </span>
      </div>
    );
  }
  return (
    <div className="note editing">
      <textarea autoFocus rows={3} value={text} placeholder="A concern or question about this region" onChange={(ev) => setText(ev.target.value)} />
      <span className="note-actions">
        <button className="btn primary" onClick={() => { setNote(r, label, text); setEditing(null); }}>
          Save
        </button>
        <button className="btn" onClick={() => setEditing(null)}>
          Cancel
        </button>
      </span>
    </div>
  );
}

export function LocationPage({ index, side, file, line, go }: { index: Index; side: "base" | "head"; file: string; line: number; go: Go }) {
  const symbols = useMemo(() => symbolTargets(index), [index]);
  const owner = index.model.components.find((c) => c.paths.some((p) => file.startsWith(p.replace(/\/?$/, "/"))));
  return (
    <div className="page-inner">
      <header className="page-head">
        <div className="eyebrow">
          Unchanged code
          {owner && (
            <>
              {" in "}
              <button className="link" onClick={() => go({ type: "interface", id: owner.id })}>
                {owner.name}
              </button>
            </>
          )}
        </div>
        <h1 className="mono-title">
          {file.split("/").pop()}:{line}
        </h1>
        <p className="muted small mono">{file}</p>
        <div className="page-actions">{side === "head" && <OpenButton file={file} line={line} />}</div>
      </header>
      <section>
        <CodeView key={`${side}:${file}:${line}`} side={side} file={file} startLine={1} focusLine={line} context={8} foldLabel="more lines" symbols={symbols} go={go} />
      </section>
    </div>
  );
}
