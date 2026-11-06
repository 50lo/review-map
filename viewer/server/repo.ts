// Node-side helpers for the local server and the single-file build: file contents at base and
// head (read with `git show`, which never writes to the repo) and opening a file in an editor.

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
  reviewItems?: Array<{
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
 * Sources for the single-file build, keyed "side:file". Files the review items live in come
 * first; files of their context regions and callers are added while the total stays under
 * `maxBytes`.
 */
export function collectSources(model: ModelLike, maxBytes: number): { sources: Record<string, string>; skipped: number } {
  const repo = repoInfo(model);
  if (!repo) return { sources: {}, skipped: 0 };
  const primary = new Set<string>();
  const secondary = new Set<string>();
  for (const e of model.reviewItems ?? []) {
    if (e.location) primary.add(`${e.location.side}:${e.location.file}`);
    if (e.baseLocation) primary.add(`base:${e.baseLocation.file}`);
  }
  for (const r of model.regions ?? []) (r.kind === "context" ? secondary : primary).add(`${r.side}:${r.file}`);
  for (const e of model.reviewItems ?? []) {
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

/** The command that opens a file at a line: a display name and its arguments, with {file} and {line} placeholders. */
export interface Editor {
  name: string;
  args: string[];
}

export const EDITOR_PRESETS: Record<string, Editor> = {
  xcode: { name: "Xcode", args: ["xed", "--line", "{line}", "{file}"] },
  vscode: { name: "VS Code", args: ["code", "-g", "{file}:{line}"] },
  cursor: { name: "Cursor", args: ["cursor", "-g", "{file}:{line}"] },
  zed: { name: "Zed", args: ["zed", "{file}:{line}"] },
  idea: { name: "IntelliJ IDEA", args: ["idea", "--line", "{line}", "{file}"] },
  webstorm: { name: "WebStorm", args: ["webstorm", "--line", "{line}", "{file}"] },
  goland: { name: "GoLand", args: ["goland", "--line", "{line}", "{file}"] },
  rustrover: { name: "RustRover", args: ["rustrover", "--line", "{line}", "{file}"] },
};

/**
 * The editor from REVIEWMAP_EDITOR: a preset name, or a command with {file} and {line}, split on
 * spaces (so no argument can contain one). Unset means Xcode on macOS and none elsewhere.
 */
export function editorFrom(value: string | undefined, platform: string = process.platform): Editor | null {
  const v = value?.trim();
  if (!v) return platform === "darwin" ? EDITOR_PRESETS.xcode : null;
  const preset = EDITOR_PRESETS[v.toLowerCase()];
  if (preset) return preset;
  if (!v.includes("{file}")) return null;
  const args = v.split(/\s+/);
  return { name: args[0].split("/").pop()!, args };
}

/** Opens a file at a line in the editor. Only inside the repo's working copy. */
export function openInEditor(editor: Editor, repo: RepoInfo, file: string, line: number): Promise<{ ok: boolean; message: string }> {
  if (!safeRelative(file)) return Promise.resolve({ ok: false, message: "Invalid path." });
  const full = path.join(repo.root, file);
  if (!fs.existsSync(full)) return Promise.resolve({ ok: false, message: `${file} isn't in the working copy at ${repo.root}.` });
  const ln = String(Math.max(1, Math.floor(line)));
  const [cmd, ...args] = editor.args.map((a) => a.replaceAll("{file}", full).replaceAll("{line}", ln));
  return new Promise((resolve) => {
    execFile(cmd, args, (err) =>
      resolve(err ? { ok: false, message: `${cmd} failed: ${err.message}` } : { ok: true, message: `Opened in ${editor.name}` }),
    );
  });
}
