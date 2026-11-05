// Where the viewer is focused, and how that maps to the URL hash. The hash holds the focus so
// browser back and forward walk the history, and a link to a view can be shared.

import type { Side } from "./types";

export type Focus =
  /** Level 1: a component selected on the map. */
  | { type: "component"; id: string }
  /** Level 1: an edge selected on the map. */
  | { type: "edge"; key: string }
  /** Level 1: the edges between two drawn nodes when one is a collapsed group. */
  | { type: "bundle"; from: string; to: string }
  /** Level 2: one component's interface view. */
  | { type: "interface"; id: string }
  /** Level 3: one entity's implementation view, optionally at one of its regions. */
  | { type: "entity"; id: string; region?: string }
  /** Level 3: a code location that has no entity, such as a caller that didn't change. */
  | { type: "location"; side: Side; file: string; line: number }
  | null;

export type Level = 1 | 2 | 3;

export const levelOf = (f: Focus): Level =>
  f?.type === "interface" ? 2 : f?.type === "entity" || f?.type === "location" ? 3 : 1;

export function focusToHash(f: Focus): string {
  if (!f) return "";
  const enc = encodeURIComponent;
  switch (f.type) {
    case "component":
      return `c=${enc(f.id)}`;
    case "edge":
      return `e=${enc(f.key)}`;
    case "bundle":
      return `b=${enc(f.from)}&t=${enc(f.to)}`;
    case "interface":
      return `i=${enc(f.id)}`;
    case "entity":
      return f.region ? `n=${enc(f.id)}&r=${enc(f.region)}` : `n=${enc(f.id)}`;
    case "location":
      return `l=${f.side}:${f.line}:${enc(f.file)}`;
  }
}

export function hashToFocus(hash: string): Focus {
  const h = new URLSearchParams(hash.replace(/^#/, ""));
  const c = h.get("c");
  if (c) return { type: "component", id: c };
  const e = h.get("e");
  if (e) return { type: "edge", key: e };
  const b = h.get("b");
  const t = h.get("t");
  if (b && t) return { type: "bundle", from: b, to: t };
  const i = h.get("i");
  if (i) return { type: "interface", id: i };
  const n = h.get("n");
  if (n) {
    const r = h.get("r");
    return r ? { type: "entity", id: n, region: r } : { type: "entity", id: n };
  }
  const l = h.get("l");
  if (l) {
    const m = /^(base|head):(\d+):(.+)$/.exec(l);
    if (m) return { type: "location", side: m[1] as Side, line: Number(m[2]), file: m[3] };
  }
  return null;
}
