import { Fragment, useEffect, useMemo, useState } from "react";
import { foldRows } from "./diff";
import { highlightFile, type Tok } from "./highlight";
import type { Focus } from "./nav";
import { getSource, sourceHint } from "./source";
import type { Side } from "./types";

export interface CodeProps {
  side: Side;
  file: string;
  /** 1-based, inclusive. Without an end, the code runs to the end of the file. */
  startLine: number;
  endLine?: number;
  /** Per shown line (0 = startLine): a mark in the gutter. */
  changed?: boolean[];
  /** Removed lines, keyed by the shown line index they follow (-1: before the first). */
  removed?: Map<number, string[]>;
  /** File line to point at, for a reference. */
  focusLine?: number;
  /** Lines of unchanged code kept around each change before the rest folds. */
  context?: number;
  /** Code shown with the removed style (a removed declaration). */
  removedStyle?: boolean;
  /** Identifiers that lead somewhere in the tool. */
  symbols?: Map<string, Focus>;
  go?: (f: Focus) => void;
  /** What folded lines are called: "unchanged lines" next to a change, "lines" otherwise. */
  foldLabel?: string;
  /** Called once the text is loaded, with the shown lines. */
  onLines?: (lines: string[] | null) => void;
}

export function useSource(side: Side, file: string) {
  const [state, setState] = useState<{ text: string | null; tokens: Tok[][] | null; loading: boolean }>({
    text: null,
    tokens: null,
    loading: true,
  });
  useEffect(() => {
    let live = true;
    if (!file) {
      setState({ text: null, tokens: null, loading: false });
      return;
    }
    setState({ text: null, tokens: null, loading: true });
    getSource(side, file).then(async (text) => {
      if (!live) return;
      if (text === null) return setState({ text: null, tokens: null, loading: false });
      setState({ text, tokens: null, loading: false });
      const tokens = await highlightFile(`${side}:${file}`, file, text);
      if (live) setState({ text, tokens, loading: false });
    });
    return () => {
      live = false;
    };
  }, [side, file]);
  return state;
}

export function CodeView(p: CodeProps) {
  const { text, tokens, loading } = useSource(p.side, p.file);
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  const [openRemoved, setOpenRemoved] = useState<Set<number>>(new Set());

  const all = useMemo(() => (text === null ? null : text.split("\n")), [text]);
  const from = Math.max(1, p.startLine);
  const to = all ? Math.min(all.length, p.endLine ?? all.length) : 0;
  const lines = useMemo(() => (all ? all.slice(from - 1, to) : null), [all, from, to]);

  useEffect(() => {
    p.onLines?.(lines);
  }, [lines]); // eslint-disable-line react-hooks/exhaustive-deps

  const rows = useMemo(() => {
    if (!lines) return [];
    const interesting: number[] = [];
    p.changed?.forEach((c, i) => c && interesting.push(i));
    for (const k of p.removed?.keys() ?? []) interesting.push(Math.max(0, Math.min(lines.length - 1, k)), Math.max(0, k + 1));
    if (p.focusLine) interesting.push(p.focusLine - from);
    if (interesting.length && p.focusLine === undefined) interesting.push(0); // keep the declaration line in view
    return foldRows(lines.length, interesting, p.context ?? 3);
  }, [lines, p.changed, p.removed, p.focusLine, p.context, from]);

  if (loading) return <div className="code-msg muted">Loading {p.file}…</div>;
  if (!lines) return <div className="code-msg muted">{sourceHint()}</div>;

  const removedMarker = (after: number) => {
    const rm = p.removed?.get(after);
    if (!rm?.length) return null;
    const open = openRemoved.has(after);
    return (
      <div className="removed-block">
        <button
          className="removed-marker"
          onClick={() => setOpenRemoved((s) => new Set(open ? [...s].filter((x) => x !== after) : [...s, after]))}
        >
          {open ? "▾" : "▸"} {rm.length} removed line{rm.length === 1 ? "" : "s"}
        </button>
        {open && (
          <div className="code-lines removed-lines">
            {rm.map((l, i) => (
              <div key={i} className="cl">
                <span className="ln" />
                <span className="lc">{l || " "}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    );
  };

  const renderLine = (i: number) => {
    const n = from + i;
    const toks = tokens?.[n - 1];
    const cls = ["cl", p.changed?.[i] ? "changed" : "", p.focusLine === n ? "focus" : ""].join(" ");
    return (
      <div key={`l${i}`} className={cls}>
        <span className="ln">{n}</span>
        <span className="lc">
          {toks ? toks.map((t, k) => <Token key={k} t={t} symbols={p.symbols} go={p.go} />) : lines[i] || " "}
          {toks && toks.length === 0 ? " " : null}
        </span>
      </div>
    );
  };

  return (
    <div className={`code ${p.removedStyle ? "is-removed" : ""}`}>
      {removedMarker(-1)}
      <div className="code-lines">
        {rows.map((r) =>
          r.kind === "line" ? (
            <Fragment key={`r${r.index}`}>
              {renderLine(r.index)}
              {p.removed?.has(r.index) && r.index !== lines.length - 1 ? removedMarker(r.index) : null}
            </Fragment>
          ) : expanded.has(r.from) ? (
            <Fragment key={`f${r.from}`}>
              {Array.from({ length: r.to - r.from + 1 }, (_, k) => renderLine(r.from + k))}
            </Fragment>
          ) : (
            <button key={`f${r.from}`} className="fold" onClick={() => setExpanded((s) => new Set([...s, r.from]))}>
              ⋯ {r.to - r.from + 1} {p.foldLabel ?? "unchanged lines"}
            </button>
          ),
        )}
      </div>
      {removedMarker(lines.length - 1)}
    </div>
  );
}

function Token({ t, symbols, go }: { t: Tok; symbols?: Map<string, Focus>; go?: (f: Focus) => void }) {
  const style = t.light ? ({ "--tl": t.light, "--td": t.dark ?? t.light } as React.CSSProperties) : undefined;
  const target = symbols && go && /^[A-Za-z_]\w*$/.test(t.text) ? symbols.get(t.text) : undefined;
  if (target) {
    return (
      <span className="tk sym" style={style} onClick={() => go!(target)} title="Go to declaration">
        {t.text}
      </span>
    );
  }
  return (
    <span className="tk" style={style}>
      {t.text}
    </span>
  );
}
