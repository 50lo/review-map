import { useState } from "react";
import { findingFocus, KIND_LABEL } from "./findings";
import type { Focus, Index } from "./graph";
import type { Anchor, Finding } from "./types";

const anchorLabel = (index: Index, a: Anchor): string => {
  const name = (id: string) => index.components.get(id)?.name ?? id;
  if (a.reviewItem) return index.reviewItems.get(a.reviewItem)?.qualifiedName ?? a.reviewItem;
  if (a.from && a.to) return `${name(a.from)} → ${name(a.to)}`;
  return a.component ? name(a.component) : "";
};

const anchorFocus = (index: Index, a: Anchor): Focus =>
  a.reviewItem && index.reviewItems.has(a.reviewItem)
    ? { type: "reviewItem", id: a.reviewItem }
    : a.from && a.to
      ? { type: "edge", key: `${a.from}->${a.to}` }
      : a.component && index.components.has(a.component)
        ? { type: "component", id: a.component }
        : null;

/** The evidence and anchors to show for a finding, when a panel shows less than all of them. */
export type FindingShape = (f: Finding) => { evidence: string[]; anchors: Anchor[] } | undefined;

/** A finding as its severity and kind alone, leading where the finding leads. */
export function FindingChip({ index, f, go }: { index: Index; f: Finding; go: (f: Focus) => void }) {
  const target = findingFocus(index, f);
  const body = (
    <>
      <span className={`sev sev-${f.severity}`}>{f.severity}</span> <span className="finding-kind">{KIND_LABEL[f.kind] ?? f.kind}</span>
    </>
  );
  return target ? (
    <button className="link finding-chip" title={f.message} onClick={() => go(target)}>
      {body}
    </button>
  ) : (
    <span className="finding-chip" title={f.message}>
      {body}
    </span>
  );
}

/** A finding as its chip and one line of context, the whole line leading where the finding leads. */
export function FindingLine({ index, f, context, go }: { index: Index; f: Finding; context: string; go: (f: Focus) => void }) {
  const target = findingFocus(index, f);
  const body = (
    <>
      <span className={`sev sev-${f.severity}`}>{f.severity}</span> <span className="finding-kind">{KIND_LABEL[f.kind] ?? f.kind}</span>{" "}
      <span className="finding-context">{context}</span>
    </>
  );
  return target ? (
    <button className="link finding-line" title={f.message} onClick={() => go(target)}>
      {body}
    </button>
  ) : (
    <div className="finding-line" title={f.message}>
      {body}
    </div>
  );
}

/** One finding: what was found, its evidence, what to do, and links to what it is anchored to. */
function FindingItem({
  index,
  f,
  go,
  hideAnchor,
  shape,
}: {
  index: Index;
  f: Finding;
  go: (f: Focus) => void;
  hideAnchor?: (a: Anchor) => boolean;
  shape?: FindingShape;
}) {
  const [open, setOpen] = useState(false);
  const target = findingFocus(index, f);
  const shaped = shape?.(f);
  const allEvidence = shaped?.evidence ?? f.evidence;
  const evidence = open ? allEvidence : allEvidence.slice(0, 3);
  const anchors = (shaped?.anchors ?? f.anchors).filter((a) => !hideAnchor?.(a) && anchorFocus(index, a));
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
      {(allEvidence.length > 3 || anchors.length > 4) && (
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
  shape,
}: {
  index: Index;
  findings: Finding[];
  go: (f: Focus) => void;
  /** Anchors not worth a link here, such as the component whose panel lists the finding. */
  hideAnchor?: (a: Anchor) => boolean;
  /** Evidence and anchors to show per finding instead of all of them. */
  shape?: FindingShape;
}) {
  if (findings.length === 0) return null;
  return (
    <ul className="findings">
      {findings.map((f) => (
        <FindingItem key={f.id} index={index} f={f} go={go} hideAnchor={hideAnchor} shape={shape} />
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
  shape,
  note,
}: {
  index: Index;
  title: string;
  findings: Finding[];
  go: (f: Focus) => void;
  limit?: number;
  hideAnchor?: (a: Anchor) => boolean;
  shape?: FindingShape;
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
      <FindingList index={index} findings={shown} go={go} hideAnchor={hideAnchor} shape={shape} />
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
