// Node-side helpers for the local server and the single-file build: file contents at base and
// head (read with `git show`, which never writes to the repo) and Open in Xcode.

import { execFile, execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

export interface RepoInfo {
  root: string;
  baseSha: string;
  headSha: string;
}

interface ModelLike {
  repo?: { root?: string; baseSha?: string; headSha?: string };
  entities?: Array<{
    location?: { file: string; side: "base" | "head" };
    baseLocation?: { file: string; side: "base" | "head" };
    usedBy?: Array<{ file: string }>;
  }>;
  regions?: Array<{ file: string; side: "base" | "head"; kind: string }>;
}

/** The repo to read sources from: REVIEWMAP_REPO, or the root recorded in the model. */
export function repoInfo(model: ModelLike): RepoInfo | null {
  const root = process.env.REVIEWMAP_REPO || model.repo?.root;
  if (!root || !model.repo?.baseSha || !model.repo?.headSha) return null;
  if (!fs.existsSync(root)) return null;
  return { root, baseSha: model.repo.baseSha, headSha: model.repo.headSha };
}

/** Rejects paths that could escape the tree or be read as an option. */
export function safeRelative(file: string): boolean {
  return !!file && !file.startsWith("/") && !file.startsWith("-") && !file.split("/").includes("..") && !file.includes("\0");
}

export function gitShow(repo: RepoInfo, side: "base" | "head", file: string): Promise<string | null> {
  if (!safeRelative(file)) return Promise.resolve(null);
  const sha = side === "base" ? repo.baseSha : repo.headSha;
  return new Promise((resolve) => {
    execFile("git", ["-C", repo.root, "show", `${sha}:${file}`], { maxBuffer: 32 * 1024 * 1024, encoding: "utf8" }, (err, out) =>
      resolve(err ? null : out),
    );
  });
}

function gitShowSync(repo: RepoInfo, side: "base" | "head", file: string): string | null {
  if (!safeRelative(file)) return null;
  const sha = side === "base" ? repo.baseSha : repo.headSha;
  try {
    return execFileSync("git", ["-C", repo.root, "show", `${sha}:${file}`], {
      maxBuffer: 32 * 1024 * 1024,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null;
  }
}

/**
 * Sources for the single-file build, keyed "side:file". Files the entities live in come
 * first; files of their context regions and callers are added while the total stays under
 * `maxBytes`.
 */
export function collectSources(model: ModelLike, maxBytes: number): { sources: Record<string, string>; skipped: number } {
  const repo = repoInfo(model);
  if (!repo) return { sources: {}, skipped: 0 };
  const primary = new Set<string>();
  const secondary = new Set<string>();
  for (const e of model.entities ?? []) {
    if (e.location) primary.add(`${e.location.side}:${e.location.file}`);
    if (e.baseLocation) primary.add(`base:${e.baseLocation.file}`);
  }
  for (const r of model.regions ?? []) (r.kind === "context" ? secondary : primary).add(`${r.side}:${r.file}`);
  for (const e of model.entities ?? []) {
    for (const u of e.usedBy ?? []) secondary.add(`head:${u.file}`);
  }
  const sources: Record<string, string> = {};
  let total = 0;
  let skipped = 0;
  for (const key of [...primary, ...[...secondary].filter((k) => !primary.has(k))]) {
    const i = key.indexOf(":");
    const text = gitShowSync(repo, key.slice(0, i) as "base" | "head", key.slice(i + 1));
    if (text === null) continue;
    if (total + text.length > maxBytes) {
      skipped++;
      continue;
    }
    sources[key] = text;
    total += text.length;
  }
  return { sources, skipped };
}

/** Opens a file at a line in Xcode with `xed`. Only on macOS, and only inside the repo. */
export function openInXcode(repo: RepoInfo, file: string, line: number): Promise<{ ok: boolean; message: string }> {
  if (process.platform !== "darwin") return Promise.resolve({ ok: false, message: "Open in Xcode needs macOS with Xcode installed." });
  if (!safeRelative(file)) return Promise.resolve({ ok: false, message: "Invalid path." });
  const full = path.join(repo.root, file);
  if (!fs.existsSync(full)) return Promise.resolve({ ok: false, message: `${file} isn't in the working copy at ${repo.root}.` });
  return new Promise((resolve) => {
    execFile("xed", ["--line", String(Math.max(1, Math.floor(line))), full], (err) =>
      resolve(err ? { ok: false, message: `xed failed: ${err.message}` } : { ok: true, message: "Opened in Xcode" }),
    );
  });
}
