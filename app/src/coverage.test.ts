import { describe, expect, it } from "vitest";
import { CANCELLED_EXPLANATION, coverageLabel, coverageSummary, stageExplanation, stageName, statusLead, worstTone } from "./coverage";
import type { CoverageGap, LanguageCoverage } from "./types";

const indexed = (id: string, files = 10, extra: Partial<LanguageCoverage> = {}): LanguageCoverage => ({ id, resolution: "index", files, indexedFiles: files, ...extra });
const partial = (id: string, indexedFiles: number, files: number): LanguageCoverage => ({ id, resolution: "index", files, indexedFiles });
const syntax = (id: string, note?: string): LanguageCoverage => ({ id, resolution: "syntax", files: 10, indexedFiles: 0, note });
const preliminary = (id: string): LanguageCoverage => ({ id, resolution: "preliminary", files: 10, indexedFiles: 0 });
const nameBased = (id: string): LanguageCoverage => ({ id, resolution: "name-based", files: 10, indexedFiles: 0 });
const gap = (language: string, changedFiles: number): CoverageGap => ({ language, changedFiles, files: changedFiles + 5, sample: [`src/${language}/A.${language}`] });

describe("worstTone", () => {
  it("ranks warn above pending above plain above ok", () => {
    expect(worstTone(["ok", "plain", "pending", "warn"])).toBe("warn");
    expect(worstTone(["ok", "pending", "plain"])).toBe("pending");
    expect(worstTone(["ok", "plain"])).toBe("plain");
    expect(worstTone(["ok", "ok"])).toBe("ok");
    expect(worstTone([])).toBe("ok");
  });
});

describe("coverageSummary", () => {
  it("says Indexed when every language is indexed", () => {
    expect(coverageSummary([indexed("swift"), indexed("kotlin")], [])).toEqual({ text: "Indexed", tone: "ok" });
  });

  it("counts the languages that are still preliminary", () => {
    expect(coverageSummary([preliminary("swift"), preliminary("kotlin"), preliminary("typescript")], undefined)).toEqual({
      text: "3 languages preliminary",
      tone: "pending",
    });
    expect(coverageSummary([preliminary("swift"), indexed("kotlin")], [])).toEqual({ text: "Swift: preliminary", tone: "pending" });
  });

  it("names the one syntax-only language on the chip", () => {
    expect(coverageSummary([indexed("swift"), syntax("kotlin", "the build failed"), preliminary("typescript")], [])).toEqual({
      text: "Kotlin: syntax only",
      tone: "warn",
    });
  });

  it("names the one partial index on the chip", () => {
    expect(coverageSummary([partial("swift", 8, 10), indexed("kotlin")], [])).toEqual({ text: "Swift: index covers 8 of 10 files", tone: "warn" });
  });

  it("warns about an indexed language whose checks were held back, as its pill did", () => {
    expect(coverageSummary([indexed("swift", 10, { heldBack: ["unused-api"] })], [])).toEqual({ text: "Swift: indexed", tone: "warn" });
  });

  it("counts several warnings", () => {
    expect(coverageSummary([syntax("swift"), partial("kotlin", 3, 4), preliminary("typescript"), indexed("java")], [])).toEqual({
      text: "2 coverage warnings",
      tone: "warn",
    });
  });

  it("adds the changed files that aren't analyzed, as a warning", () => {
    expect(coverageSummary([indexed("swift")], [gap("java", 3), gap("objc", 1), gap("c", 0)])).toEqual({
      text: "Indexed · 4 files not analyzed",
      tone: "warn",
    });
    expect(coverageSummary([preliminary("swift"), preliminary("kotlin")], [gap("java", 1)])).toEqual({
      text: "2 languages preliminary · 1 file not analyzed",
      tone: "warn",
    });
    expect(coverageSummary([], [gap("java", 2)])).toEqual({ text: "2 files not analyzed", tone: "warn" });
  });

  it("ignores gaps without changed files", () => {
    expect(coverageSummary([indexed("swift")], [gap("java", 0)])).toEqual({ text: "Indexed", tone: "ok" });
  });

  it("says nothing without languages or gaps", () => {
    expect(coverageSummary([], [])).toBeNull();
    expect(coverageSummary([], [gap("java", 0)])).toBeNull();
  });

  it("describes the comparison report as matched by name", () => {
    expect(coverageSummary([nameBased("swift")], [])).toEqual({ text: "Swift: matched by name", tone: "plain" });
    expect(coverageSummary([nameBased("swift"), nameBased("kotlin")], [])).toEqual({ text: "2 languages matched by name", tone: "plain" });
  });

  it("takes its tone from the worst language's label", () => {
    const languages = [indexed("swift"), preliminary("kotlin"), nameBased("typescript")];
    expect(coverageSummary(languages, [])!.tone).toBe(worstTone(languages.map((l) => coverageLabel(l).tone)));
  });
});

describe("coverageLabel", () => {
  it("keeps each language's text and explanation", () => {
    expect(coverageLabel(syntax("kotlin", "indexes are off"))).toEqual({
      text: "Kotlin: syntax only",
      tone: "warn",
      title: "No index: indexes are off. Only links that syntax proves are shown, and the checks that need every reference did not run.",
    });
    expect(coverageLabel(partial("swift", 8, 10)).title).toBe(
      "Files the index doesn't cover at both sides show only links that syntax proves. The warnings list them.",
    );
    expect(coverageLabel(indexed("swift", 10, { heldBack: ["unused-api", "orphaned"] })).title).toBe(
      "Every reference comes from the compiler's index. Not run: unused-api, orphaned; the warnings say why.",
    );
  });
});

describe("stageName", () => {
  it("names each stage in a few words", () => {
    expect(stageName("preliminary", true)).toBe("Preliminary");
    expect(stageName("graph", true)).toBe("Build graph ready, indexing");
    expect(stageName("graph", false)).toBe("Build graph ready");
    expect(stageName("complete", false)).toBe("Analysis complete");
  });
});

describe("stageExplanation", () => {
  it("explains what is still to come", () => {
    expect(stageExplanation("preliminary", true, true)).toBe("Preliminary: components are Bazel packages and only links that syntax proves are shown.");
    expect(stageExplanation("preliminary", true, false)).toBe("Preliminary: only links that syntax proves are shown until the index is ready.");
    expect(stageExplanation("preliminary", false, true)).toBe("Components are Bazel packages until Bazel reports the build graph.");
    expect(stageExplanation("preliminary", false, false)).toBeNull();
    expect(stageExplanation("graph", true, true)).toBe("Components and declared dependencies come from Bazel. References are still preliminary.");
    expect(stageExplanation("graph", false, true)).toBeNull();
    expect(stageExplanation("complete", false, true)).toBeNull();
  });
});

describe("statusLead", () => {
  const job = (state: Partial<{ running: boolean; cancelled: boolean }>) => ({ running: false, cancelled: false, ...state });

  it("names the stage while running", () => {
    expect(statusLead(job({ running: true }), null, "preliminary", true).text).toBe("Preliminary");
    expect(statusLead(job({ running: true }), null, "graph", true).text).toBe("Build graph ready, indexing");
  });

  it("says Cancelled and keeps the explanation in the tooltip", () => {
    expect(statusLead(job({ cancelled: true }), null, "graph", false)).toEqual({ text: "Cancelled", tone: "warn", title: CANCELLED_EXPLANATION });
  });

  it("shows the first line of the error and keeps all of it in the tooltip", () => {
    expect(statusLead(job({}), "bazel query failed\nexit code 1", "preliminary", false)).toEqual({
      text: "Stopped: bazel query failed",
      tone: "warn",
      title: "bazel query failed\nexit code 1",
    });
  });

  it("says the analysis is complete once it is", () => {
    expect(statusLead(job({}), null, "complete", false).text).toBe("Analysis complete");
    expect(statusLead(null, null, "complete", false).text).toBe("Analysis complete");
  });
});
