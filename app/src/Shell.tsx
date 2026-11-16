// What surrounds the viewer in the app: the screen that starts a review, and the bar that says how far
// the analysis got, how each language was resolved, and lets the reviewer cancel or compare.

import { useEffect, useRef, useState } from "react";
import * as backend from "./backend";
import type { JobState, RecentReview, ReviewRequest } from "./backend";
import { changedGaps, coverageLabel, coverageSummary, gapText, stageExplanation, statusLead } from "./coverage";
import type { ChangeReport } from "./types";

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

// One line. On the left, how far the analysis got and its latest progress message; on the right, one chip that
// sums up every language's coverage in the worst tone among them, with each language's details a click away.
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
  const languages = analysis?.languages ?? [];
  // What is still to come. A language that is syntax-only from the start (indexes are off) has nothing pending.
  const pending = languages.some((l) => l.resolution === "preliminary");
  // Without a Bazel workspace in the change, components are already final (npm packages, folders).
  const bazel = (analysis?.workspaces ?? []).length > 0 || report.components.some((c) => c.kind === "bazelPackage");
  const explanation = running ? stageExplanation(stage, pending, bazel) : null;
  const lead = statusLead(job, error, stage, pending);
  const summary = coverageSummary(languages, analysis?.gaps);
  return (
    <div className={`statusbar ${running ? "running" : ""}`}>
      <div className="status-main">
        {running && <span className="spinner" />}
        <span className={`status-lead ${lead.tone}`} title={lead.title || explanation || undefined}>
          {lead.text}
        </span>
        {running && (
          <>
            <span className="status-message muted" title={job?.message}>
              {job?.message || "Analyzing…"}
            </span>
            <button className="link" onClick={onCancel}>
              Cancel
            </button>
          </>
        )}
      </div>
      {summary && <CoverageChip summary={summary} report={report} explanation={explanation} />}
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

// The coverage chip and its popover, which lists everything the chip sums up: each language's coverage with its
// explanation, the changed files that aren't analyzed, and what the current stage means.
function CoverageChip({ summary, report, explanation }: { summary: { text: string; tone: string }; report: ChangeReport; explanation: string | null }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const down = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false);
    };
    // Captured, so Escape closes the popover without also leaving the current focus on the map.
    const key = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.stopPropagation();
      setOpen(false);
    };
    document.addEventListener("mousedown", down);
    document.addEventListener("keydown", key, true);
    return () => {
      document.removeEventListener("mousedown", down);
      document.removeEventListener("keydown", key, true);
    };
  }, [open]);
  const labels = (report.analysis?.languages ?? []).map((c) => ({ id: c.id, ...coverageLabel(c) }));
  const gaps = changedGaps(report.analysis?.gaps);
  return (
    <span className="status-coverage" ref={ref}>
      <button
        className={`pill coverage-chip ${summary.tone}`}
        aria-haspopup="dialog"
        aria-expanded={open}
        title={[...labels.map((l) => l.text), ...gaps.map(gapText)].join("\n")}
        onClick={() => setOpen((o) => !o)}
      >
        {summary.text}
      </button>
      {open && (
        <div className="coverage-popover" role="dialog" aria-label="Coverage">
          {explanation && <p className="coverage-stage">{explanation}</p>}
          {labels.length > 0 && (
            <ul>
              {labels.map((l) => (
                <li key={l.id}>
                  <span className={`pill ${l.tone}`}>{l.text}</span>
                  <span className="muted">{l.title}</span>
                </li>
              ))}
            </ul>
          )}
          {gaps.length > 0 && (
            <ul>
              {gaps.map((g) => (
                <li key={g.language}>
                  <span className="pill warn">{gapText(g)}</span>
                  <span className="muted">Not analyzed: {g.sample.join(", ")}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </span>
  );
}
