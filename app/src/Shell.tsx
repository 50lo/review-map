// What surrounds the viewer in the app: the screen that starts a review, and the bar that says how far
// the analysis got, how each language was resolved, and lets the reviewer cancel or compare.

import { useEffect, useState } from "react";
import * as backend from "./backend";
import type { JobState, RecentReview, ReviewRequest } from "./backend";
import type { ChangeReport, LanguageCoverage } from "./types";

const LANGUAGE_NAMES: Record<string, string> = { swift: "Swift", kotlin: "Kotlin", typescript: "TypeScript", java: "Java", objc: "Objective-C" };
const languageName = (id: string) => LANGUAGE_NAMES[id] ?? id;

const splitList = (text: string) => text.split(/\s+/).filter(Boolean);

// The form's fields hold paths, refs, and labels, not prose: the system's spelling, completion, and writing
// help would only get in the way.
const PLAIN_TEXT = { spellCheck: false, autoComplete: "off", autoCorrect: "off", autoCapitalize: "off", writingsuggestions: "false" } as const;

// ---------------------------------------------------------------------------
// Start

export function StartScreen({
  job,
  starting,
  error,
  onStart,
  onCancel,
}: {
  job: JobState | null;
  starting: boolean;
  error: string | null;
  onStart: (r: ReviewRequest) => void;
  onCancel: () => void;
}) {
  const last = job?.request;
  const [repo, setRepo] = useState(last?.repo ?? "");
  const [base, setBase] = useState(last?.base ?? "main");
  const [head, setHead] = useState(last?.head ?? "");
  const [branch, setBranch] = useState("");
  const [targets, setTargets] = useState((last?.targets ?? []).join(" "));
  const [bazelArgs, setBazelArgs] = useState((last?.bazelArgs ?? []).join(" "));
  const [mergeBase, setMergeBase] = useState(last?.useMergeBase ?? true);
  const [index, setIndex] = useState(last?.index !== false);
  const [repoError, setRepoError] = useState<string | null>(null);
  const [recent, setRecent] = useState<RecentReview[]>([]);
  const running = !!job?.running || starting;

  useEffect(() => {
    backend
      .recentReviews()
      .then(setRecent)
      .catch(() => setRecent([]));
  }, []);

  // The repository's root and current branch, as soon as the path names a repository.
  useEffect(() => {
    if (!repo.trim()) {
      setBranch("");
      setRepoError(null);
      return;
    }
    let alive = true;
    const timer = setTimeout(() => {
      backend
        .repoDefaults(repo.trim())
        .then((d) => {
          if (!alive) return;
          setBranch(d.branch);
          setRepoError(null);
        })
        .catch((e) => {
          if (!alive) return;
          setBranch("");
          setRepoError(String(e?.message ?? e));
        });
    }, 250);
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [repo]);

  const submit = () =>
    onStart({
      repo: repo.trim(),
      base: base.trim() || "main",
      head: head.trim() || undefined,
      useMergeBase: mergeBase,
      targets: splitList(targets),
      bazelArgs: splitList(bazelArgs),
      index: index ? undefined : false,
    });

  const fill = (r: RecentReview) => {
    setRepo(r.repo);
    setBase(r.base);
    setHead(r.head ?? "");
    setTargets(r.targets.join(" "));
    setBazelArgs(r.bazelArgs.join(" "));
  };

  return (
    <div className="empty start-screen">
      <h1>Review Map</h1>
      {running ? (
        <div className="start-progress">
          <p>
            <span className="spinner" /> {job?.message || "Starting the review…"}
          </p>
          {job && (
            <p className="muted small">
              {job.request.repo} · {job.request.base} → {job.request.head || "current branch"}
            </p>
          )}
          <button className="btn" onClick={onCancel}>
            Cancel
          </button>
        </div>
      ) : (
        <form
          className="start-form"
          onSubmit={(e) => {
            e.preventDefault();
            if (repo.trim()) submit();
          }}
        >
          <label>
            <span>Repository</span>
            <span className="start-row">
              <input value={repo} onChange={(e) => setRepo(e.target.value)} placeholder="/path/to/repo" {...PLAIN_TEXT} autoFocus />
              <button
                type="button"
                className="btn"
                onClick={() =>
                  backend
                    .chooseFolder()
                    .then((p) => p && setRepo(p))
                    .catch(() => undefined)
                }
              >
                Choose…
              </button>
            </span>
            {repoError && <span className="error small">{repoError}</span>}
          </label>
          <div className="start-row two">
            <label>
              <span>Base</span>
              <input value={base} onChange={(e) => setBase(e.target.value)} placeholder="main" {...PLAIN_TEXT} />
            </label>
            <label>
              <span>Head</span>
              <input value={head} onChange={(e) => setHead(e.target.value)} placeholder={branch ? `${branch} (checked out)` : "the checked-out branch"} {...PLAIN_TEXT} />
            </label>
          </div>
          <label>
            <span>Bazel targets that define the review scope</span>
            <input value={targets} onChange={(e) => setTargets(e.target.value)} placeholder="from reviewmap.yml or rules_xcodeproj, e.g. //App:App //App:AppTests" {...PLAIN_TEXT} />
          </label>
          <label>
            <span>Extra Bazel arguments</span>
            <input value={bazelArgs} onChange={(e) => setBazelArgs(e.target.value)} placeholder="from reviewmap.yml, e.g. --config=sim" {...PLAIN_TEXT} />
          </label>
          <div className="start-row checks">
            <label className="check">
              <input type="checkbox" checked={mergeBase} onChange={(e) => setMergeBase(e.target.checked)} />
              Compare against the merge-base, as a pull request does
            </label>
            <label className="check">
              <input type="checkbox" checked={index} onChange={(e) => setIndex(e.target.checked)} />
              Build indexes for exact references (without them, only links that syntax proves are shown)
            </label>
          </div>
          <button className="btn primary" type="submit" disabled={!repo.trim()}>
            Review
          </button>
          <p className="muted small">
            Or run <code>reviewmap</code> in a repository to review its current branch against main here.
          </p>
        </form>
      )}
      {error && <p className="error start-error">{error}</p>}
      {!running && recent.length > 0 && (
        <div className="recent">
          <h2>Recent</h2>
          <ul>
            {recent.map((r, i) => (
              <li key={i}>
                <button className="link" onClick={() => fill(r)} title={r.repo}>
                  {r.repo.split("/").pop()} · {r.base} → {r.head || "current branch"}
                </button>
                <span className="muted small"> {r.repo}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Status

function coverageLabel(c: LanguageCoverage): { text: string; tone: string; title: string } {
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

export function StatusBar({
  job,
  report,
  variant,
  comparing,
  error,
  onVariant,
  onCancel,
  onNewReview,
}: {
  job: JobState | null;
  report: ChangeReport;
  variant: "indexed" | "name-based";
  comparing: boolean;
  error: string | null;
  onVariant: (v: "indexed" | "name-based") => void;
  onCancel: () => void;
  onNewReview: () => void;
}) {
  const analysis = report.analysis;
  const running = !!job?.running;
  const stage = analysis?.stage ?? "complete";
  const gaps = (analysis?.gaps ?? []).filter((g) => g.changedFiles > 0);
  // What is still to come. A language that is syntax-only from the start (indexes are off) has nothing pending.
  const pending = (analysis?.languages ?? []).some((l) => l.resolution === "preliminary");
  // Without a Bazel workspace in the change, components are already final (npm packages, folders).
  const bazel = (analysis?.workspaces ?? []).length > 0 || report.components.some((c) => c.kind === "bazelPackage");
  const stageText =
    stage === "preliminary"
      ? pending
        ? bazel
          ? "Preliminary: components are Bazel packages and only links that syntax proves are shown."
          : "Preliminary: only links that syntax proves are shown until the index is ready."
        : bazel
          ? "Components are Bazel packages until Bazel reports the build graph."
          : null
      : stage === "graph" && pending
        ? "Components and declared dependencies come from Bazel. References are still preliminary."
        : null;
  return (
    <div className={`statusbar ${running ? "running" : ""}`}>
      <div className="status-main">
        {running ? (
          <>
            <span className="spinner" />
            <span className="status-message" title={job?.message}>
              {job?.message || "Analyzing…"}
            </span>
            <button className="link" onClick={onCancel}>
              Cancel
            </button>
          </>
        ) : job?.cancelled ? (
          <span className="pill warn" title="Languages whose index wasn't ready show only links that syntax proves.">
            Cancelled: the report shows what was ready
          </span>
        ) : error ? (
          <span className="pill warn" title={error}>
            The analysis stopped: {error.split("\n")[0]}
          </span>
        ) : (
          <span className="muted">Analysis complete</span>
        )}
        {running && stageText && <span className="pill pending">{stageText}</span>}
      </div>
      <div className="status-coverage">
        {(analysis?.languages ?? []).map((c) => {
          const l = coverageLabel(c);
          return (
            <span key={c.id} className={`pill ${l.tone}`} title={l.title}>
              {l.text}
            </span>
          );
        })}
        {gaps.map((g) => (
          <span key={g.language} className="pill warn" title={`Not analyzed: ${g.sample.join(", ")}`}>
            {g.changedFiles} changed {languageName(g.language)} file{g.changedFiles === 1 ? "" : "s"} not analyzed
          </span>
        ))}
      </div>
      <div className="status-actions">
        <span className="segmented" title="Compare the indexed report with the one that matches every reference by name, for the same revisions.">
          <button className={variant === "indexed" ? "on" : ""} onClick={() => onVariant("indexed")}>
            Indexed
          </button>
          <button className={variant === "name-based" ? "on" : ""} disabled={running || comparing} onClick={() => onVariant("name-based")}>
            {comparing ? "Matching…" : "By name"}
          </button>
        </span>
        <button className="link" onClick={onNewReview} disabled={running}>
          New review
        </button>
      </div>
    </div>
  );
}
