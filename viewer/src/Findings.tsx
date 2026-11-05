import { useState } from "react";
import { findingFocus, KIND_LABEL } from "./findings";
import type { Focus, Index } from "./graph";
import type { Anchor, Finding } from "./types";

const anchorLabel = (index: Index, a: Anchor): string => {
  const name = (id: string) => index.components.get(id)?.name ?? id;
  if (a.entity) return index.entities.get(a.entity)?.qualifiedName ?? a.entity;
  if (a.from && a.to) return `${name(a.from)} → ${name(a.to)}`;
  return a.component ? name(a.component) : "";
};

const anchorFocus = (index: Index, a: Anchor): Focus =>
  a.entity && index.entities.has(a.entity)
    ? { type: "entity", id: a.entity }
    : a.from && a.to
      ? { type: "edge", key: `${a.from}->${a.to}` }
      : a.component && index.components.has(a.component)
        ? { type: "component", id: a.component }
        : null;

/** One finding: what was found, its evidence, what to do, and links to what it is anchored to. */
function FindingItem({ index, f, go, hideAnchor }: { index: Index; f: Finding; go: (f: Focus) => void; hideAnchor?: (a: Anchor) => boolean }) {
  const [open, setOpen] = useState(false);
  const target = findingFocus(index, f);
  const evidence = open ? f.evidence : f.evidence.slice(0, 3);
  const anchors = f.anchors.filter((a) => !hideAnchor?.(a) && anchorFocus(index, a));
  const shownAnchors = open ? anchors : anchors.slice(0, 4);
  return (
    <li>
      <div className="finding-head">
        <span className={`sev sev-${f.severity}`}>{f.severity}</span>
        <span className="finding-kind">{KIND_LABEL[f.kind] ?? f.kind}</span>
        {f.source === "llm" && (
          <span className="finding-src" title="From the LLM's structural review">
            LLM
          </span>
        )}
      </div>
      {target ? (
        <button className="link finding-msg" onClick={() => go(target)}>
          {f.message}
        </button>
      ) : (
        <div className="finding-msg">{f.message}</div>
      )}
      {evidence.length > 0 && (
        <ul className="finding-evidence">
          {evidence.map((x, i) => (
            <li key={i}>{x}</li>
          ))}
        </ul>
      )}
      {f.suggestion && <div className="finding-suggestion">{f.suggestion}</div>}
      {shownAnchors.length > 0 && (
        <div className="finding-anchors">
          {shownAnchors.map((a, i) => (
            <button key={i} className="link mono" onClick={() => go(anchorFocus(index, a))}>
              {anchorLabel(index, a)}
            </button>
          ))}
        </div>
      )}
      {(f.evidence.length > 3 || anchors.length > 4) && (
        <button className="link small" onClick={() => setOpen(!open)}>
          {open ? "Less" : "More"}
        </button>
      )}
    </li>
  );
}

export function FindingList({
  index,
  findings,
  go,
  hideAnchor,
}: {
  index: Index;
  findings: Finding[];
  go: (f: Focus) => void;
  /** Anchors not worth a link here, such as the component whose panel lists the finding. */
  hideAnchor?: (a: Anchor) => boolean;
}) {
  if (findings.length === 0) return null;
  return (
    <ul className="findings">
      {findings.map((f) => (
        <FindingItem key={f.id} index={index} f={f} go={go} hideAnchor={hideAnchor} />
      ))}
    </ul>
  );
}

/** A titled section of findings, behind a "show all" past the first few. */
export function FindingsSection({
  index,
  title,
  findings,
  go,
  limit = 5,
  hideAnchor,
  note,
}: {
  index: Index;
  title: string;
  findings: Finding[];
  go: (f: Focus) => void;
  limit?: number;
  hideAnchor?: (a: Anchor) => boolean;
  note?: string;
}) {
  const [all, setAll] = useState(false);
  if (findings.length === 0 && !note) return null;
  const shown = all ? findings : findings.slice(0, limit);
  return (
    <section>
      <h2>
        {title} <span className="muted">{findings.length}</span>
      </h2>
      {note && <p className="small muted">{note}</p>}
      <FindingList index={index} findings={shown} go={go} hideAnchor={hideAnchor} />
      {findings.length > limit && (
        <p className="small">
          <button className="link" onClick={() => setAll(!all)}>
            {all ? "Show fewer" : `Show all ${findings.length}`}
          </button>
        </p>
      )}
    </section>
  );
}
