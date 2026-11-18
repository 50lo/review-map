// Exporting the review notes: the last step of a review, when the notes go into the real code review. Every
// way to export (the sidebar's NOTES section, the toolbar's Notes popover, the finish prompt and the menu
// bar's two items) goes through here, so all of them export the same Markdown, `notesMarkdown(notes)`.

import * as backend from "./backend";
import type { Focus } from "./nav";
import { notesMarkdown, type Note } from "./review";

/** The notes by region id, in file order: the order `notesMarkdown` writes them in. */
export function sortedNotes(notes: Record<string, Note>): [string, Note][] {
  return Object.entries(notes).sort(([, a], [, b]) => a.file.localeCompare(b.file) || a.startLine - b.startLine);
}

/** Where a note opens: its region on its review item's page, or its code location when the region is gone. */
export function noteTarget(regions: { has(id: string): boolean }, regionId: string, n: Note): Focus {
  return regions.has(regionId) ? { type: "reviewItem", id: n.reviewItem, region: regionId } : { type: "location", side: n.side, file: n.file, line: n.startLine };
}

/** `file:line` or `file:start-end`, as the Markdown writes it. */
export const noteLocation = (n: Note) => `${n.file}:${n.endLine > n.startLine ? `${n.startLine}-${n.endLine}` : n.startLine}`;

/** Puts the notes' Markdown on the clipboard. False when that failed; the failure is in the app log. */
export async function copyNotes(notes: Record<string, Note>): Promise<boolean> {
  try {
    await backend.copyText(notesMarkdown(notes));
    return true;
  } catch (e) {
    void backend.logUiError(`copy notes: ${(e as Error)?.message ?? e}`);
    return false;
  }
}

export type SaveResult = "saved" | "dismissed" | "failed";

/** Saves the notes' Markdown to a file picked in the save dialog, `review-notes.md` by default. */
export async function saveNotes(notes: Record<string, Note>): Promise<SaveResult> {
  try {
    return (await backend.exportNotes(notesMarkdown(notes))) ? "saved" : "dismissed";
  } catch (e) {
    void backend.logUiError(`export notes: ${(e as Error)?.message ?? e}`);
    return "failed";
  }
}

export const EXPORT_NOTES = "export-notes";
export const COPY_NOTES = "copy-notes";

/** Runs the menu bar's File → Export Notes… or Edit → Copy Notes as Markdown. Null for any other menu item. */
export function notesMenuAction(id: string, notes: Record<string, Note>): Promise<unknown> | null {
  if (id === EXPORT_NOTES) return saveNotes(notes);
  if (id === COPY_NOTES) return copyNotes(notes);
  return null;
}
