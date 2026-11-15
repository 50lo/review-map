import type { ChangeReport } from "./types";

/** Reports the UI can show: version 5 from the app's core, and version 4 from the prototype (the logic tests read its fixtures). */
export const SUPPORTED_VERSION = 5;

export function validate(raw: unknown): ChangeReport {
  const m = raw as Partial<ChangeReport>;
  if (!m || typeof m !== "object" || !Array.isArray(m.components) || !Array.isArray(m.edges)) {
    throw new Error("This doesn't look like a change report (no components or edges).");
  }
  if ("entities" in m) {
    throw new Error(`This change report was written by an older reviewmap (version ${m.version ?? 1}).`);
  }
  return {
    version: m.version ?? 1,
    analyzer: m.analyzer,
    repo: m.repo ?? { root: "", base: "", head: "", baseSha: "", headSha: "" },
    analysis: m.analysis,
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
