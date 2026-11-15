// File contents at base or head, for levels 2 and 3. The app's core reads them from the repository's
// object database at the report's commits; it never touches the working copy.

import type { Side } from "./types";
import * as backend from "./backend";

const cache = new Map<string, Promise<string | null>>();
let editor: string | null = null;

/** Forgets cached sources. Call when another review is shown. */
export function resetSources(editorName: string | null) {
  cache.clear();
  editor = editorName;
}

export function getSource(side: Side, file: string): Promise<string | null> {
  const key = `${side}:${file}`;
  let p = cache.get(key);
  if (!p) {
    p = backend.readSource(side, file).catch(() => null);
    cache.set(key, p);
  }
  return p;
}

/** Why sources are missing, for the message shown in their place. */
export function sourceHint(): string {
  return "This file can't be read from the repository at that commit.";
}

/** Name of the editor that Open uses, or null. */
export const editorName = (): string | null => editor;

export const canOpenInEditor = () => !!editor;

export async function openInEditor(file: string, line: number): Promise<string> {
  try {
    return await backend.openInEditor(file, line);
  } catch (e) {
    return String(e);
  }
}
