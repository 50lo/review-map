// Levels 2 and 3 of the viewer: a component's interface view, an entity's implementation view,
// and a plain code location.

import { useMemo, useState } from "react";
import { CodeView, useSource } from "./CodeView";
import { lineChanges } from "./diff";
import { componentEdges, type Index } from "./graph";
import {
  dependsOnTarget,
  groupUsages,
  interfaceModel,
  lastName,
  membersOf,
  neighbors,
  symbolTargets,
  usedByTarget,
} from "./levels";
import type { Focus } from "./nav";
import { EdgeList } from "./Sidebar";
import { canOpenInXcode, openInXcode } from "./source";
import type { Entity, Usage } from "./types";
import { ChangeTag, Chips, Signature } from "./ui";

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
      </header>

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

function EntityCard({ index, e, go }: { index: Index; e: Entity; go: Go }) {
  return (
    <article className="card">
      <button className="card-title" onClick={() => go({ type: "entity", id: e.id })}>
        <span className="kind">{e.kind}</span> <span className="qname">{e.qualifiedName}</span> <ChangeTag change={e.change} />
        <span className="chev">›</span>
      </button>
      <Signature e={e} />
      <Chips flags={e.contractFlags} />
      <Usages index={index} title="Used by" usages={e.usedBy ?? []} target={(u) => usedByTarget(index, u)} go={go} />
      <Usages index={index} title="Depends on" usages={e.dependsOn ?? []} target={(u) => dependsOnTarget(index, u)} go={go} />
    </article>
  );
}

const OneLiner = ({ e, go }: { e: Entity; go: Go }) => (
  <li>
    <button className="one-liner" onClick={() => go({ type: "entity", id: e.id })}>
      <span className="kind">{e.kind}</span> <span className="qname">{e.qualifiedName}</span> <ChangeTag change={e.change} />
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

function XcodeButton({ file, line }: { file: string; line: number }) {
  const [msg, setMsg] = useState<string | null>(null);
  if (!canOpenInXcode()) return null;
  return (
    <span className="xcode">
      <button className="btn" onClick={() => openInXcode(file, line).then(setMsg)} title={`${file}:${line} in your working copy`}>
        Open in Xcode
      </button>
      {msg && <span className="muted small"> {msg}</span>}
    </span>
  );
}

export function EntityPage({ index, id, go }: { index: Index; id: string; go: Go }) {
  const e = index.entities.get(id);
  if (!e) return <div className="page-inner muted">No entity {id} in this change.</div>;
  return <EntityPageInner key={id} index={index} e={e} go={go} />;
}

function EntityPageInner({ index, e, go }: { index: Index; e: Entity; go: Go }) {
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

  // Changed lines inside the entity, until the analyzer emits review regions (milestone 4).
  const changes = useMemo(() => {
    if (!base || baseSrc.text === null || headSrc.text === null) return undefined;
    const b = baseSrc.text.split("\n").slice(base.startLine - 1, base.endLine);
    const h = headSrc.text.split("\n").slice(loc.startLine - 1, loc.endLine);
    return lineChanges(b, h);
  }, [base, baseSrc.text, headSrc.text, loc]);
  const firstChanged = changes ? changes.changed.findIndex(Boolean) : -1;
  const changedCount = changes ? changes.changed.filter(Boolean).length : 0;
  const removedCount = changes ? [...changes.removed.values()].reduce((s, l) => s + l.length, 0) : 0;

  return (
    <div className="page-inner">
      <header className="page-head">
        <div className="eyebrow">
          {e.kind} in{" "}
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
        <div className="page-actions">
          <span className="stepper">
            <button className="btn" disabled={!nb.prev} onClick={() => nb.prev && go({ type: "entity", id: nb.prev.id })}>
              ‹ Prev
            </button>
            <span className="muted small">
              {nb.position} of {nb.total}
            </span>
            <button className="btn" disabled={!nb.next} onClick={() => nb.next && go({ type: "entity", id: nb.next.id })}>
              Next ›
            </button>
          </span>
          {!isRemoved && loc.side === "head" && (
            <XcodeButton file={loc.file} line={loc.startLine + Math.max(0, firstChanged)} />
          )}
        </div>
      </header>

      {members.length > 0 && (
        <section>
          <h2>
            Changed members <span className="count">{members.length}</span>
          </h2>
          <ul className="one-liners">
            {members.map((m) => (
              <OneLiner key={m.id} e={{ ...m, qualifiedName: lastName(m.qualifiedName) }} go={go} />
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
        {e.change === "added" && <p className="muted small">New declaration.</p>}
        {changes && (changedCount > 0 || removedCount > 0) && (
          <p className="muted small">
            <span className="mark-sample" /> {changedCount} changed line{changedCount === 1 ? "" : "s"}
            {removedCount > 0 ? `, ${removedCount} removed` : ""}. Unchanged code is folded.
          </p>
        )}
        <CodeView
          side={loc.side}
          file={loc.file}
          startLine={loc.startLine}
          endLine={loc.endLine}
          changed={changes?.changed}
          removed={changes?.removed}
          removedStyle={isRemoved}
          symbols={symbols}
          go={go}
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
        <div className="page-actions">{side === "head" && <XcodeButton file={file} line={line} />}</div>
      </header>
      <section>
        <CodeView key={`${side}:${file}:${line}`} side={side} file={file} startLine={1} focusLine={line} context={8} foldLabel="more lines" symbols={symbols} go={go} />
      </section>
    </div>
  );
}
