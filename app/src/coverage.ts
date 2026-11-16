// What the status bar says about how far the analysis got and how each language was resolved: the short
// stage name, the long stage explanation, each language's coverage, and the one-chip summary of them all.
// Pure functions, so every state the bar can show is unit-tested (coverage.test.ts).

import type { CoverageGap, LanguageCoverage } from "./types";

const LANGUAGE_NAMES: Record<string, string> = { swift: "Swift", kotlin: "Kotlin", typescript: "TypeScript", java: "Java", objc: "Objective-C" };
export const languageName = (id: string) => LANGUAGE_NAMES[id] ?? id;

/** How a piece of coverage reads: a warning, still to come, neutral, or complete. */
export type Tone = "warn" | "pending" | "plain" | "ok";

// Worst first: a warning outranks what is still to come, which outranks a neutral note, which outranks
// complete coverage. The chip that summarizes every language takes the worst tone among them.
const TONE_RANK: Record<Tone, number> = { warn: 3, pending: 2, plain: 1, ok: 0 };

export function worstTone(tones: Tone[]): Tone {
  return tones.reduce<Tone>((worst, t) => (TONE_RANK[t] > TONE_RANK[worst] ? t : worst), "ok");
}

export function coverageLabel(c: LanguageCoverage): { text: string; tone: Tone; title: string } {
  const name = languageName(c.id);
  const heldBack = c.heldBack ?? [];
  const notRun = heldBack.length ? ` Not run: ${heldBack.join(", ")}; the warnings say why.` : "";
  if (c.resolution === "index") {
    const partial = c.indexedFiles < c.files;
    return {
      text: partial ? `${name}: index covers ${c.indexedFiles} of ${c.files} files` : `${name}: indexed`,
      tone: partial || heldBack.length ? "warn" : "ok",
      title:
        (partial
          ? "Files the index doesn't cover at both sides show only links that syntax proves. The warnings list them."
          : "Every reference comes from the compiler's index.") + notRun,
    };
  }
  if (c.resolution === "syntax") {
    return {
      text: `${name}: syntax only`,
      tone: "warn",
      title: `No index${c.note ? `: ${c.note}` : ""}. Only links that syntax proves are shown, and the checks that need every reference did not run.`,
    };
  }
  if (c.resolution === "name-based") {
    return { text: `${name}: matched by name`, tone: "plain", title: "The comparison report: references are matched by name, as without an index." };
  }
  return { text: `${name}: preliminary`, tone: "pending", title: "Only links that syntax proves are shown until the index is ready." };
}

/** Languages with changed files that aren't analyzed; a gap without changed files says nothing. */
export const changedGaps = (gaps: CoverageGap[] | undefined) => (gaps ?? []).filter((g) => g.changedFiles > 0);

export const gapText = (g: CoverageGap) => `${g.changedFiles} changed ${languageName(g.language)} file${g.changedFiles === 1 ? "" : "s"} not analyzed`;

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/**
 * One line for every language's coverage and the files that aren't analyzed, in the worst tone among them.
 * A warning names its language while it is the only one, so a syntax-only language or a partial index shows
 * on the chip itself (CORE-003). Null when there is nothing to say.
 */
export function coverageSummary(languages: LanguageCoverage[], gaps: CoverageGap[] | undefined): { text: string; tone: Tone } | null {
  const labels = languages.map(coverageLabel);
  const missing = changedGaps(gaps);
  if (!labels.length && !missing.length) return null;
  const tone = worstTone([...labels.map((l) => l.tone), ...(missing.length ? (["warn"] as Tone[]) : [])]);
  const of = (t: Tone) => labels.filter((l) => l.tone === t);
  const warn = of("warn");
  const pending = of("pending");
  const plain = of("plain");
  const languagesText = !labels.length
    ? ""
    : warn.length
      ? warn.length === 1
        ? warn[0].text
        : `${warn.length} coverage warnings`
      : pending.length
        ? pending.length === 1
          ? pending[0].text
          : `${pending.length} languages preliminary`
        : plain.length
          ? plain.length === 1
            ? plain[0].text
            : `${plain.length} languages matched by name`
          : "Indexed";
  const files = missing.reduce((n, g) => n + g.changedFiles, 0);
  const gapsText = files ? `${plural(files, "file", "files")} not analyzed` : "";
  return { text: [languagesText, gapsText].filter(Boolean).join(" · "), tone };
}

/** The short name of the analysis stage, for the left of the status bar. */
export function stageName(stage: string, pending: boolean): string {
  if (stage === "preliminary") return "Preliminary";
  if (stage === "graph") return pending ? "Build graph ready, indexing" : "Build graph ready";
  return "Analysis complete";
}

/**
 * What the current stage means for the map, while the analysis still runs: whether components are final and
 * which links are shown. Null once nothing is still to come.
 *
 * `pending`: some language's index is still to come. `bazel`: the change has a Bazel workspace, so
 * components are Bazel packages until Bazel reports the build graph.
 */
export function stageExplanation(stage: string, pending: boolean, bazel: boolean): string | null {
  if (stage === "preliminary") {
    if (pending)
      return bazel
        ? "Preliminary: components are Bazel packages and only links that syntax proves are shown."
        : "Preliminary: only links that syntax proves are shown until the index is ready.";
    return bazel ? "Components are Bazel packages until Bazel reports the build graph." : null;
  }
  if (stage === "graph" && pending) return "Components and declared dependencies come from Bazel. References are still preliminary.";
  return null;
}

export const CANCELLED_EXPLANATION = "Cancelled: the report shows what was ready. Languages whose index wasn't ready show only links that syntax proves.";

/**
 * The left of the status bar when the analysis isn't running: the stage name, or how the analysis ended.
 * `title` holds the full text the label may cut short.
 */
export function statusLead(
  job: { running: boolean; cancelled: boolean } | null,
  error: string | null,
  stage: string,
  pending: boolean,
): { text: string; tone: Tone | "muted"; title: string } {
  if (job?.running) return { text: stageName(stage, pending), tone: "muted", title: "" };
  if (job?.cancelled) return { text: "Cancelled", tone: "warn", title: CANCELLED_EXPLANATION };
  if (error) return { text: `Stopped: ${error.split("\n")[0]}`, tone: "warn", title: error };
  return { text: stageName(stage, pending), tone: "muted", title: "" };
}
