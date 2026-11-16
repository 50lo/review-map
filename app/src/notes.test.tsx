import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Note } from "./review";

// The notes reach the code review through four entry points: the sidebar's NOTES section, the toolbar's Notes
// popover, the finish prompt, and the menu bar. All of them must export exactly notesMarkdown(notes).
const copied: string[] = [];
const exported: string[] = [];
vi.mock("./backend", () => ({
  copyText: vi.fn(async (text: string) => {
    copied.push(text);
  }),
  exportNotes: vi.fn(async (markdown: string) => {
    exported.push(markdown);
    return "/tmp/review-notes.md";
  }),
  logUiError: vi.fn(async () => undefined),
}));

const { notesMarkdown } = await import("./review");
const { copyNotes, saveNotes, notesMenuAction, noteTarget, sortedNotes } = await import("./notesExport");
const { NotesButton, ReviewProgress } = await import("./Notes");

const note = (file: string, startLine: number, label: string, extra: Partial<Note> = {}): Note => ({
  text: `about ${label}`,
  reviewItem: `item-${label}`,
  label,
  file,
  startLine,
  endLine: startLine,
  side: "head",
  ...extra,
});

// Out of file order on purpose.
const notes: Record<string, Note> = {
  r3: note("b/Second.swift", 4, "Second.run"),
  r1: note("a/First.swift", 30, "First.late", { endLine: 34 }),
  r2: note("a/First.swift", 2, "First.early", { side: "base" }),
};
const regions = new Set(["r1", "r3"]);
const noop = () => undefined;

const html = (el: React.ReactElement) => renderToStaticMarkup(el);
const text = (markup: string) => markup.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();

describe("Notes button", () => {
  it("is hidden without notes", () => {
    expect(html(<NotesButton notes={{}} regions={regions} setFocus={noop} />)).toBe("");
  });

  it("shows the note count", () => {
    expect(text(html(<NotesButton notes={notes} regions={regions} setFocus={noop} />))).toBe("Notes 3");
    expect(text(html(<NotesButton notes={{ r1: notes.r1 }} regions={regions} setFocus={noop} />))).toBe("Notes 1");
  });

  it("lists every note in file order, with its location, and the two actions", () => {
    const shown = text(html(<NotesButton notes={notes} regions={regions} setFocus={noop} initiallyOpen />));
    const order = ["First.early", "First.late", "Second.run"].map((l) => shown.indexOf(l));
    expect(order.every((i) => i >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
    expect(shown).toContain("a/First.swift:2 (removed code)");
    expect(shown).toContain("a/First.swift:30-34");
    expect(shown).toContain("Copy as Markdown");
    expect(shown).toContain("Download .md");
  });

  it("keeps the order notesMarkdown writes", () => {
    const md = notesMarkdown(notes);
    const positions = sortedNotes(notes).map(([, n]) => md.indexOf(n.label));
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);
    expect(sortedNotes(notes).map(([id]) => id)).toEqual(["r2", "r1", "r3"]);
  });
});

describe("a note's target", () => {
  it("is its region on its review item's page", () => {
    expect(noteTarget(regions, "r1", notes.r1)).toEqual({ type: "reviewItem", id: "item-First.late", region: "r1" });
  });

  it("is its code location when the region is gone", () => {
    expect(noteTarget(regions, "r2", notes.r2)).toEqual({ type: "location", side: "base", file: "a/First.swift", line: 2 });
  });
});

describe("finish prompt", () => {
  it("shows progress only while review items are left", () => {
    expect(text(html(<ReviewProgress done={3} total={5} notes={notes} />))).toBe("3/5 reviewed");
  });

  it("offers to copy the notes once everything is reviewed", () => {
    expect(text(html(<ReviewProgress done={5} total={5} notes={notes} />))).toBe("All 5 reviewed Copy notes");
  });

  it("says there are no notes once everything is reviewed without any", () => {
    expect(text(html(<ReviewProgress done={5} total={5} notes={{}} />))).toBe("All 5 reviewed No notes");
  });

  it("isn't shown for a report with nothing to review", () => {
    expect(text(html(<ReviewProgress done={0} total={0} notes={notes} />))).toBe("0/0 reviewed");
  });
});

describe("every entry point exports the same Markdown", () => {
  beforeEach(() => {
    copied.length = 0;
    exported.length = 0;
  });

  it("copies and saves notesMarkdown(notes)", async () => {
    const md = notesMarkdown(notes);
    expect(md).not.toBe("");
    // The sidebar's and the popover's buttons, and the finish prompt.
    expect(await copyNotes(notes)).toBe(true);
    expect(await saveNotes(notes)).toBe("saved");
    // The menu bar's Edit → Copy Notes as Markdown and File → Export Notes….
    await notesMenuAction("copy-notes", notes);
    await notesMenuAction("export-notes", notes);
    expect(copied).toEqual([md, md]);
    expect(exported).toEqual([md, md]);
  });

  it("leaves other menu items alone", () => {
    expect(notesMenuAction("new-review", notes)).toBeNull();
    expect(notesMenuAction("compare-name-based", notes)).toBeNull();
    expect(copied).toEqual([]);
    expect(exported).toEqual([]);
  });

  it("reports a dismissed save dialog and a failed copy", async () => {
    const backend = await import("./backend");
    vi.mocked(backend.exportNotes).mockResolvedValueOnce(null);
    vi.mocked(backend.copyText).mockRejectedValueOnce(new Error("pbcopy exited 1"));
    expect(await saveNotes(notes)).toBe("dismissed");
    expect(await copyNotes(notes)).toBe(false);
    expect(backend.logUiError).toHaveBeenCalledWith("copy notes: pbcopy exited 1");
  });
});
