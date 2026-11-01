// File contents at base or head, for levels 2 and 3. The single-file build embeds them in the
// page; the local server reads them from the repo with `git show`.

import type { Side } from "./types";
import { modelOrigin } from "./load";

declare global {
  interface Window {
    __REVIEWMAP_SOURCES__?: Record<string, string>;
  }
}

const cache = new Map<string, Promise<string | null>>();

export function getSource(side: Side, file: string): Promise<string | null> {
  const key = `${side}:${file}`;
  let p = cache.get(key);
  if (!p) {
    const embedded = window.__REVIEWMAP_SOURCES__;
    if (embedded) p = Promise.resolve(embedded[key] ?? null);
    else if (modelOrigin() !== "server") p = Promise.resolve(null);
    else
      p = fetch(`/api/source?side=${side}&file=${encodeURIComponent(file)}`)
        .then((r) => (r.ok ? r.text() : null))
        .catch(() => null);
    cache.set(key, p);
  }
  return p;
}

/** Why sources are missing, for the message shown in their place. */
export function sourceHint(): string {
  if (window.__REVIEWMAP_SOURCES__) return "This file wasn't embedded in the page.";
  if (modelOrigin() === "server") return "The server couldn't read this file from the repo at that commit.";
  return "Code is shown when the viewer runs with `reviewmap --view`, which can read the repo.";
}

/** Open in Xcode works only through the local server, on the machine that has the repo. */
export const canOpenInXcode = () => modelOrigin() === "server" && !window.__REVIEWMAP_SOURCES__;

export async function openInXcode(file: string, line: number): Promise<string> {
  try {
    const r = await fetch(`/api/open?file=${encodeURIComponent(file)}&line=${line}`, { method: "POST" });
    return await r.text();
  } catch (e) {
    return `Couldn't reach the server: ${String(e)}`;
  }
}
