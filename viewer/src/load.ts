import type { ChangeModel } from "./types";

declare global {
  interface Window {
    __REVIEWMAP_MODEL__?: ChangeModel;
  }
}

export const SUPPORTED_VERSION = 1;

export type ModelOrigin = "embedded" | "server" | "url" | "file";
let origin: ModelOrigin = "file";
/** Where the model came from. Only the local server can read sources from the repo and open Xcode. */
export const modelOrigin = () => origin;

export function validate(raw: unknown): ChangeModel {
  const m = raw as Partial<ChangeModel>;
  if (!m || typeof m !== "object" || !Array.isArray(m.components) || !Array.isArray(m.edges)) {
    throw new Error("This doesn't look like a change-model.json (no components or edges).");
  }
  return {
    version: m.version ?? 1,
    analyzer: m.analyzer,
    repo: m.repo ?? { root: "", base: "", head: "", baseSha: "", headSha: "" },
    components: m.components,
    edges: m.edges,
    externalDeps: m.externalDeps ?? [],
    entities: m.entities ?? [],
    regions: m.regions ?? [],
    warnings: m.warnings ?? [],
  };
}

/**
 * Where the model comes from, in order: embedded in the page (single-file build),
 * a `?model=<url>` parameter, or the local server's /api/model. Null means none was found,
 * and the page asks for a file.
 */
export async function loadInitialModel(): Promise<ChangeModel | null> {
  if (window.__REVIEWMAP_MODEL__) {
    origin = "embedded";
    return validate(window.__REVIEWMAP_MODEL__);
  }
  const param = new URLSearchParams(location.search).get("model");
  const url = param ?? "/api/model";
  try {
    const res = await fetch(url, { cache: "no-store" });
    if (!res.ok) {
      if (param) throw new Error(`Couldn't load ${param}: HTTP ${res.status}`);
      return null;
    }
    const model = validate(await res.json());
    origin = param ? "url" : "server";
    return model;
  } catch (err) {
    if (param) throw err;
    return null;
  }
}

export async function loadFile(file: File): Promise<ChangeModel> {
  origin = "file";
  return validate(JSON.parse(await file.text()));
}
