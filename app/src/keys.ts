// The app's own keyboard shortcuts that the page handles (the menu bar's are in app/src-tauri/src/menu.rs).
// They don't use letter keys, which sit in different places on different keyboard layouts.

/** The parts of a key press the shortcuts look at. */
export interface KeyPress {
  key: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
}

/**
 * Which way a key press steps through the regions in risk order: 1 for the next region, -1 for the previous
 * one, 0 when it isn't a region key. ⌘→ and ⌘← step, as do ] and [ without modifiers.
 */
export function regionStep(e: KeyPress): 1 | -1 | 0 {
  const onlyCmd = e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey;
  const none = !e.metaKey && !e.ctrlKey && !e.altKey;
  if ((onlyCmd && e.key === "ArrowRight") || (none && e.key === "]")) return 1;
  if ((onlyCmd && e.key === "ArrowLeft") || (none && e.key === "[")) return -1;
  return 0;
}

/** How the region keys are written in hints. */
export const NEXT_REGION_KEY = "⌘→";
export const PREVIOUS_REGION_KEY = "⌘←";
