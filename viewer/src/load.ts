import type { ChangeReport } from "./types";

declare global {
  interface Window {
    __REVIEWMAP_REPORT__?: ChangeReport;
  }
}

export const SUPPORTED_VERSION = 4;

export type ReportOrigin = "embedded" | "server" | "url" | "file";
let origin: ReportOrigin = "file";
/** Where the report came from. Only the local server can read sources from the repo and open files in the editor. */
export const reportOrigin = () => origin;

export function validate(raw: unknown): ChangeReport {
  const m = raw as Partial<ChangeReport>;
  if (!m || typeof m !== "object" || !Array.isArray(m.components) || !Array.isArray(m.edges)) {
    throw new Error("This doesn't look like a change-report.json (no components or edges).");
  }
  if ("entities" in m) {
    throw new Error(`This change report was written by an older reviewmap (version ${m.version ?? 1}). Run reviewmap again to update it.`);
  }
  return {
    version: m.version ?? 1,
    analyzer: m.analyzer,
    repo: m.repo ?? { root: "", base: "", head: "", baseSha: "", headSha: "" },
    components: m.components,
    edges: m.edges,
    externalDeps: m.externalDeps ?? [],
    reviewItems: m.reviewItems ?? [],
    regions: m.regions ?? [],
    warnings: m.warnings ?? [],
    findings: m.findings ?? [],
    llm: m.llm,
  };
}

/**
 * Where the report comes from, in order: embedded in the page (single-file build),
 * a `?report=<url>` parameter, or the local server's /api/report. Null means none was found,
 * and the page asks for a file.
 */
export async function loadInitialReport(): Promise<ChangeReport | null> {
  if (window.__REVIEWMAP_REPORT__) {
    origin = "embedded";
    return validate(window.__REVIEWMAP_REPORT__);
  }
  const param = new URLSearchParams(location.search).get("report");
  const url = param ?? "/api/report";
  try {
    const res = await fetch(url, { cache: "no-store" });
    if (!res.ok) {
      if (param) throw new Error(`Couldn't load ${param}: HTTP ${res.status}`);
      return null;
    }
    const report = validate(await res.json());
    origin = param ? "url" : "server";
    return report;
  } catch (err) {
    if (param) throw err;
    return null;
  }
}

export async function loadFile(file: File): Promise<ChangeReport> {
  origin = "file";
  return validate(JSON.parse(await file.text()));
}
