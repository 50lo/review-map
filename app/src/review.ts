// Reviewed marks and notes. The app keeps them in its data directory, apart from the disposable
// analysis cache, in one file per repository and head ref, keyed by the head commit: a new analysis of
// a moved branch starts fresh, and a report that is refined in place keeps its marks.

import { useSyncExternalStore } from "react";
import * as backend from "./backend";
import type { ChangeReport, Region, Side } from "./types";

export interface Note {
  text: string;
  reviewItem: string;
  /** The review item's qualified name when the note was written. */
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
let target: { root: string; head: string; headSha: string } | null = null;
let saveTimer: ReturnType<typeof setTimeout> | undefined;
const listeners = new Set<() => void>();

/** Loads the saved state for this report. Call once per review, before rendering the viewer. */
export async function initReview(report: ChangeReport): Promise<void> {
  target = { root: report.repo.root, head: report.repo.head, headSha: report.repo.headSha || "unknown" };
  let loaded: Partial<ReviewState> | undefined;
  try {
    loaded = ((await backend.loadReviewState(target.root, target.head, target.headSha)) as Partial<ReviewState> | null) ?? undefined;
  } catch {
    /* no saved state */
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
  if (!target) return;
  try {
    await backend.saveReviewState(target.root, target.head, target.headSha, state);
  } catch {
    /* the next change retries */
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

export function setReviewed(reviewItemId: string, on: boolean) {
  const reviewed = { ...state.reviewed };
  if (on) reviewed[reviewItemId] = true;
  else delete reviewed[reviewItemId];
  update({ ...state, reviewed });
}

export function setNote(region: Region, label: string, text: string | null) {
  const notes = { ...state.notes };
  if (text && text.trim()) {
    notes[region.id] = {
      text: text.trim(),
      reviewItem: region.reviewItem,
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
