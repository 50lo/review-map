// The review notes in the UI: the list of notes, the Copy and Download actions, the toolbar's Notes button
// with its popover, and the finish prompt next to the toolbar's progress. They take the notes as props;
// exporting is in notesExport.ts.

import { useEffect, useRef, useState } from "react";
import type { Focus } from "./nav";
import { copyNotes, noteLocation, noteTarget, saveNotes, sortedNotes, type SaveResult } from "./notesExport";
import type { Note } from "./review";

type Notes = Record<string, Note>;
type Regions = { has(id: string): boolean };

/** An action's outcome, shown for two seconds in place of the button's label. */
function useFlash<T>(): [T | null, (v: T) => void] {
  const [value, setValue] = useState<T | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>();
  useEffect(() => () => clearTimeout(timer.current), []);
  return [
    value,
    (v: T) => {
      clearTimeout(timer.current);
      setValue(v);
      timer.current = setTimeout(() => setValue(null), 2000);
    },
  ];
}

/** The notes in file order, each a link to its region (or its code location when the region is gone). */
export function NotesList({ notes, regions, onOpen, locations = false }: { notes: Notes; regions: Regions; onOpen: (f: Focus) => void; locations?: boolean }) {
  return (
    <ul className="notes-list">
      {sortedNotes(notes).map(([id, n]) => (
        <li key={id}>
          <button className="link mono small" title={`Open ${noteLocation(n)}`} onClick={() => onOpen(noteTarget(regions, id, n))}>
            {n.label}
          </button>
          {locations && (
            <div className="muted small note-location">
              {noteLocation(n)}
              {n.side === "base" ? " (removed code)" : ""}
            </div>
          )}
          <div className="small">{n.text}</div>
        </li>
      ))}
    </ul>
  );
}

const saveText: Record<SaveResult, string> = { saved: "Saved", dismissed: "Download .md", failed: "Couldn't save" };

/** "Copy as Markdown" and "Download .md": the clipboard, or a file picked in the save dialog. */
export function NotesActions({ notes }: { notes: Notes }) {
  const [copied, flashCopied] = useFlash<boolean>();
  const [saved, flashSaved] = useFlash<SaveResult>();
  return (
    <p className="small notes-actions">
      <button className="btn" onClick={() => void copyNotes(notes).then(flashCopied)}>
        {copied === null ? "Copy as Markdown" : copied ? "Copied" : "Couldn't copy"}
      </button>{" "}
      <button className="btn" title="Save the notes as a Markdown file (review-notes.md)" onClick={() => void saveNotes(notes).then(flashSaved)}>
        {saveText[saved ?? "dismissed"]}
      </button>
    </p>
  );
}

/**
 * The toolbar's "Notes N" button, at every level, and its popover with the notes and the two actions. Hidden
 * when there are no notes. The popover closes on Escape, on a click outside it, and after opening a note.
 */
export function NotesButton({ notes, regions, setFocus, initiallyOpen = false }: { notes: Notes; regions: Regions; setFocus: (f: Focus) => void; initiallyOpen?: boolean }) {
  const [open, setOpen] = useState(initiallyOpen);
  const ref = useRef<HTMLDivElement>(null);
  const count = Object.keys(notes).length;
  useEffect(() => {
    if (!open) return;
    const down = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false);
    };
    // Captured, so Escape closes the popover without also moving the focus up a level.
    const key = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.stopPropagation();
      setOpen(false);
    };
    // Captured too: the map's zoom handler stops a mousedown from reaching the document.
    document.addEventListener("mousedown", down, true);
    document.addEventListener("keydown", key, true);
    return () => {
      document.removeEventListener("mousedown", down, true);
      document.removeEventListener("keydown", key, true);
    };
  }, [open]);
  // The last note was deleted while the popover was open.
  useEffect(() => {
    if (count === 0) setOpen(false);
  }, [count]);
  if (count === 0) return null;
  return (
    <div className="notes-control" ref={ref}>
      <button className="btn notes-btn" aria-haspopup="dialog" aria-expanded={open} title="Your notes, to copy or save for the code review" onClick={() => setOpen((o) => !o)}>
        Notes <span className="notes-count">{count}</span>
      </button>
      {open && (
        <div className="notes-popover" role="dialog" aria-label="Notes">
          <NotesList
            notes={notes}
            regions={regions}
            locations
            onOpen={(f) => {
              setOpen(false);
              setFocus(f);
            }}
          />
          <NotesActions notes={notes} />
        </div>
      )}
    </div>
  );
}

/**
 * The toolbar's review progress: "X/Y reviewed", and once all are reviewed "All Y reviewed" with the finish
 * prompt: "Copy notes" when there are notes, "No notes" when there are none.
 */
export function ReviewProgress({ done, total, notes }: { done: number; total: number; notes: Notes }) {
  const allDone = total > 0 && done === total;
  return (
    <>
      <span className={`next-progress ${allDone ? "all-done" : ""}`} title={`${done} of ${total} review items reviewed. Tests, generated code and cosmetic changes aren't counted.`}>
        {allDone ? `All ${total} reviewed` : `${done}/${total} reviewed`}
      </span>
      {allDone && <FinishNotes notes={notes} />}
    </>
  );
}

function FinishNotes({ notes }: { notes: Notes }) {
  const [copied, flashCopied] = useFlash<boolean>();
  const count = Object.keys(notes).length;
  if (count === 0) return <span className="finish-notes muted small">No notes</span>;
  return (
    <button className="btn primary finish-notes" title={`Copy your ${count} note${count === 1 ? "" : "s"} as Markdown, for the code review`} onClick={() => void copyNotes(notes).then(flashCopied)}>
      {copied === null ? "Copy notes" : copied ? "Copied" : "Couldn't copy"}
    </button>
  );
}
