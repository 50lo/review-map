// Reviewed marks and notes. With the local server they're saved in a file next to the change
// model (`<model>.review.json`); otherwise, as in the single-file build, in browser storage.
// Both are keyed by the head commit, so a new analysis of a moved branch starts fresh.

import { useSyncExternalStore } from "react";
import { modelOrigin } from "./load";
import type { ChangeReport, Region, Side } from "./types";

export interface Note {
  text: string;
  entity: string;
  /** The entity's qualified name when the note was written. */
  label: string;
  file: string;
  startLine: number;
  endLine: number;
  side: Side;
}

export interface ReviewState {
  reviewed: Record<string, true>;
  /** By region id. */
  notes: Record<string, Note>;
}

const empty = (): ReviewState => ({ reviewed: {}, notes: {} });

let state: ReviewState = empty();
let headSha = "";
let useServer = false;
let saveTimer: ReturnType<typeof setTimeout> | undefined;
const listeners = new Set<() => void>();

const localKey = () => `reviewmap.review.${headSha}`;

/** Loads the saved state for this model. Call once before rendering the viewer. */
export async function initReview(model: ChangeReport): Promise<void> {
  headSha = model.repo.headSha || "unknown";
  useServer = modelOrigin() === "server" && !window.__REVIEWMAP_SOURCES__;
  let loaded: Partial<ReviewState> | undefined;
  if (useServer) {
    try {
      const r = await fetch("/api/review", { cache: "no-store" });
      if (r.ok) loaded = (await r.json())?.[headSha];
    } catch {
      /* no saved state */
    }
  } else {
    try {
      loaded = JSON.parse(localStorage.getItem(localKey()) ?? "null") ?? undefined;
    } catch {
      /* storage unavailable */
    }
  }
  state = { reviewed: loaded?.reviewed ?? {}, notes: loaded?.notes ?? {} };
  emit();
}

/** Replaces the state, for tests. */
export function resetReview(s: ReviewState = empty()) {
  state = s;
  emit();
}

function emit() {
  for (const l of listeners) l();
}

function update(next: ReviewState) {
  state = next;
  emit();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, 300);
}

async function save() {
  if (useServer) {
    try {
      await fetch("/api/review", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ headSha, state }),
      });
    } catch {
      /* the next change retries */
    }
    return;
  }
  try {
    localStorage.setItem(localKey(), JSON.stringify(state));
  } catch {
    /* storage unavailable: marks last for this page only */
  }
}

export function useReview(): ReviewState {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => state,
  );
}

export function setReviewed(entityId: string, on: boolean) {
  const reviewed = { ...state.reviewed };
  if (on) reviewed[entityId] = true;
  else delete reviewed[entityId];
  update({ ...state, reviewed });
}

export function setNote(region: Region, label: string, text: string | null) {
  const notes = { ...state.notes };
  if (text && text.trim()) {
    notes[region.id] = {
      text: text.trim(),
      entity: region.entity,
      label,
      file: region.file,
      startLine: region.startLine,
      endLine: region.endLine,
      side: region.side,
    };
  } else delete notes[region.id];
  update({ ...state, notes });
}

/** Notes as Markdown, in file order, ready to paste into a review. */
export function notesMarkdown(notes: Record<string, Note>): string {
  const list = Object.values(notes).sort((a, b) => a.file.localeCompare(b.file) || a.startLine - b.startLine);
  if (list.length === 0) return "";
  const out = ["## Review notes", ""];
  for (const n of list) {
    const lines = n.endLine > n.startLine ? `${n.startLine}-${n.endLine}` : `${n.startLine}`;
    out.push(`**\`${n.file}:${lines}\`**${n.side === "base" ? " (removed code)" : ""} · ${n.label}`, "", n.text, "");
  }
  return out.join("\n");
}
