// Small diff helpers for levels 2 and 3. They never produce a diff view: level 2 highlights the
// changed tokens of a head signature, and level 3 marks changed head lines and turns removed
// lines into collapsed markers.

/** Longest common subsequence of a and b, as matched index pairs in order. */
function lcs<T>(a: T[], b: T[], eq: (x: T, y: T) => boolean): Array<[number, number]> {
  const n = a.length;
  const m = b.length;
  // Trim the common prefix and suffix first: most review item changes touch a few lines.
  let pre = 0;
  while (pre < n && pre < m && eq(a[pre], b[pre])) pre++;
  let suf = 0;
  while (suf < n - pre && suf < m - pre && eq(a[n - 1 - suf], b[m - 1 - suf])) suf++;
  const pairs: Array<[number, number]> = [];
  for (let i = 0; i < pre; i++) pairs.push([i, i]);
  const an = n - pre - suf;
  const bm = m - pre - suf;
  if (an > 0 && bm > 0) {
    if (an * bm > 4_000_000) {
      // Too large to compare exactly; treat the middle as fully replaced.
    } else {
      const w = bm + 1;
      const t = new Uint32Array((an + 1) * w);
      for (let i = an - 1; i >= 0; i--) {
        for (let j = bm - 1; j >= 0; j--) {
          t[i * w + j] = eq(a[pre + i], b[pre + j]) ? t[(i + 1) * w + j + 1] + 1 : Math.max(t[(i + 1) * w + j], t[i * w + j + 1]);
        }
      }
      let i = 0;
      let j = 0;
      while (i < an && j < bm) {
        if (eq(a[pre + i], b[pre + j])) {
          pairs.push([pre + i, pre + j]);
          i++;
          j++;
        } else if (t[(i + 1) * w + j] >= t[i * w + j + 1]) i++;
        else j++;
      }
    }
  }
  for (let k = suf; k > 0; k--) pairs.push([n - k, m - k]);
  return pairs;
}

export interface Segment {
  text: string;
  changed: boolean;
}

const tokenize = (s: string) => s.match(/[A-Za-z_][A-Za-z0-9_]*|\d+|\s+|./g) ?? [];

/**
 * Splits the head signature into segments, marking the tokens that are not in the base
 * signature. Whitespace never counts as a change.
 */
export function signatureSegments(base: string | undefined, head: string): Segment[] {
  const h = tokenize(head);
  if (base === undefined || base === head) return [{ text: head, changed: false }];
  const bt = tokenize(base).filter((t) => !/^\s+$/.test(t));
  const hIdx = h.map((t, i) => [t, i] as const).filter(([t]) => !/^\s+$/.test(t));
  const kept = new Set(lcs(bt, hIdx.map(([t]) => t), (x, y) => x === y).map(([, j]) => hIdx[j][1]));
  const isWs = (t: string) => /^\s+$/.test(t);
  const flags = h.map((t, i) => !isWs(t) && !kept.has(i));
  // Whitespace between two changed tokens reads as part of one change.
  h.forEach((t, i) => {
    if (isWs(t) && i > 0 && i < h.length - 1) flags[i] = flags[i - 1] && flags[i + 1];
  });
  const out: Segment[] = [];
  h.forEach((t, i) => {
    const changed = flags[i];
    const last = out[out.length - 1];
    if (last && last.changed === changed) last.text += t;
    else out.push({ text: t, changed });
  });
  return out;
}

export interface LineChanges {
  /** Per head line: true when the line is new or modified. */
  changed: boolean[];
  /**
   * Removed base lines, keyed by the head line index they follow (-1: before the first line).
   */
  removed: Map<number, string[]>;
}

const norm = (s: string) => s.trim().replace(/\s+/g, " ");

/** Compares base and head lines of one review item, ignoring indentation and spacing. */
export function lineChanges(base: string[], head: string[]): LineChanges {
  const pairs = lcs(base.map(norm), head.map(norm), (x, y) => x === y);
  const changed = head.map(() => true);
  const removed = new Map<number, string[]>();
  let bi = 0;
  let hi = 0;
  const flushRemoved = (until: number) => {
    const lines: string[] = [];
    for (; bi < until; bi++) if (norm(base[bi]) !== "") lines.push(base[bi]);
    if (lines.length) removed.set(hi - 1, [...(removed.get(hi - 1) ?? []), ...lines]);
  };
  for (const [b, h] of pairs) {
    hi = h;
    flushRemoved(b);
    changed[h] = false;
    bi = b + 1;
  }
  hi = head.length;
  flushRemoved(base.length);
  // Blank lines that changed are not worth a mark.
  head.forEach((l, i) => {
    if (norm(l) === "") changed[i] = false;
  });
  return { changed, removed };
}

export type Row = { kind: "line"; index: number } | { kind: "fold"; from: number; to: number };

/**
 * Which lines to show: every line within `context` of an interesting line, with longer runs of
 * other lines folded. Short snippets are shown whole.
 */
export function foldRows(count: number, interesting: number[], context = 3, showAllBelow = 30): Row[] {
  if (count <= showAllBelow || interesting.length === 0) {
    return Array.from({ length: count }, (_, index) => ({ kind: "line" as const, index }));
  }
  const keep = new Array<boolean>(count).fill(false);
  for (const i of interesting) {
    for (let k = Math.max(0, i - context); k <= Math.min(count - 1, i + context); k++) keep[k] = true;
  }
  const rows: Row[] = [];
  let i = 0;
  while (i < count) {
    if (keep[i]) {
      rows.push({ kind: "line", index: i++ });
      continue;
    }
    let j = i;
    while (j < count && !keep[j]) j++;
    // A fold that hides only a line or two costs more than it saves.
    if (j - i <= 2) for (let k = i; k < j; k++) rows.push({ kind: "line", index: k });
    else rows.push({ kind: "fold", from: i, to: j - 1 });
    i = j;
  }
  return rows;
}
