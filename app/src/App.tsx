import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { ChangeReport } from "./types";
import * as backend from "./backend";
import type { JobState, ReviewEvent, ReviewRequest } from "./backend";
import {
  buildIndex,
  carryFocus,
  collapse,
  defaultCollapsed,
  edgeKey,
  isGroupOf,
  mapFocus,
  nextUnreviewed,
  regionPosition,
  revealFocus,
  reviewProgress,
  sameComponents,
  stepRegion,
  visible,
  type Index,
  type MapOptions,
} from "./graph";
import { lastName } from "./levels";
import { validate } from "./load";
import { MapView } from "./MapView";
import { focusToHash, hashToFocus, levelOf, type Focus } from "./nav";
import { ReviewItemPage, InterfacePage, LocationPage } from "./Pages";
import { NotesButton, ReviewProgress } from "./Notes";
import { notesMenuAction } from "./notesExport";
import { initReview, useReview } from "./review";
import { Sidebar } from "./Sidebar";
import { forgetSources, resetSources } from "./source";
import { ComparisonBanner, StartScreen, StatusBar } from "./Shell";

// Focus lives in the URL hash, so browser back/forward walk the focus history.
const readFocus = (): Focus => hashToFocus(location.hash);

function writeFocus(f: Focus) {
  const hash = focusToHash(f);
  if (location.hash.slice(1) === hash) return;
  history.pushState(null, "", hash ? `#${hash}` : location.pathname + location.search);
}

/** One level up: review item → its component's interface view → that component on the map → the map. */
function parentFocus(index: Index, f: Focus): Focus {
  if (!f) return null;
  if (f.type === "reviewItem") {
    const e = index.reviewItems.get(f.id);
    return e ? { type: "interface", id: e.component } : null;
  }
  if (f.type === "interface") return { type: "component", id: f.id };
  return null;
}

interface Crumb {
  label: string;
  focus?: Focus;
}

function crumbs(index: Index, f: Focus): Crumb[] {
  const name = (id: string) => index.components.get(id)?.name ?? id;
  switch (f?.type) {
    case undefined:
      return [];
    case "component":
      return [{ label: name(f.id) }];
    case "edge": {
      const e = index.report.edges.find((x) => edgeKey(x) === f.key);
      return [{ label: e ? `${name(e.from)} → ${name(e.to)}` : f.key }];
    }
    case "bundle":
      return [{ label: `${name(f.from)} → ${name(f.to)}` }];
    case "interface":
      return [{ label: name(f.id) }];
    case "reviewItem": {
      const e = index.reviewItems.get(f.id);
      if (!e) return [{ label: f.id }];
      return [{ label: name(e.component), focus: { type: "interface", id: e.component } }, { label: lastName(e.qualifiedName) }];
    }
    case "location":
      return [{ label: `${f.file.split("/").pop()}:${f.line}` }];
  }
}

/**
 * Where "next" (j, ], the toolbar's Next) goes. On a review item: the next region in risk order. Anywhere
 * else: the riskiest region whose review item isn't reviewed, or, once all are, the riskiest region.
 */
function nextRegion(index: Index, reviewed: Record<string, boolean>, focus: Focus): Focus {
  if (focus?.type === "reviewItem") return stepRegion(index, focus, 1);
  return nextUnreviewed(index, reviewed) ?? stepRegion(index, focus, 1);
}

const sameFocus = (a: Focus, b: Focus) => JSON.stringify(a) === JSON.stringify(b);

/**
 * The toolbar's "what next" control, at every level. On a review item: the region's place in risk order
 * with previous and next. Elsewhere: the next unreviewed review item. Progress counts review items, the
 * same numbers as the Overview's Progress section; once all are reviewed, it offers to copy the notes.
 * Hidden when the report has no risk regions.
 */
function NextControl({ index, focus, setFocus }: { index: Index; focus: Focus; setFocus: (f: Focus) => void }) {
  const { reviewed, notes } = useReview();
  if (index.riskOrder.length === 0) return null;
  const { done, total } = reviewProgress(index, reviewed);
  const progress = <ReviewProgress done={done} total={total} notes={notes} />;
  const order = `${index.llm ? "LLM " : ""}risk`;
  if (focus?.type === "reviewItem") {
    const pos = regionPosition(index, focus);
    const n = index.riskOrder.length;
    const prev = stepRegion(index, focus, -1);
    const next = stepRegion(index, focus, 1);
    return (
      <div className="next-control">
        <span className="stepper" title={`Regions across the change, highest ${order} first (keys k and j)`}>
          <button className="btn" title="Previous region (k)" disabled={sameFocus(prev, focus)} onClick={() => setFocus(prev)}>
            ‹
          </button>
          <span className="small">{pos ? `Region ${pos} of ${n}` : `${n} regions`}</span>
          <button className="btn" title="Next region (j)" disabled={sameFocus(next, focus)} onClick={() => setFocus(next)}>
            ›
          </button>
        </span>
        {progress}
      </div>
    );
  }
  const target = nextUnreviewed(index, reviewed);
  const item = target?.type === "reviewItem" ? index.reviewItems.get(target.id) : undefined;
  return (
    <div className="next-control">
      {target && item && (
        <button
          className="btn primary next-btn"
          title={`Next unreviewed: ${item.qualifiedName}, at its riskiest region (by ${order}).\nKeys: j next region, k previous region.`}
          onClick={() => setFocus(target)}
        >
          Next: <span className="next-name">{lastName(item.qualifiedName)}</span> ›
        </button>
      )}
      {progress}
    </div>
  );
}

const OPTIONS_KEY = "reviewmap.options.v2";
const LLM_KEY = "reviewmap.llm";

function readLLM(): boolean {
  try {
    return localStorage.getItem(LLM_KEY) !== "off";
  } catch {
    return true;
  }
}

function readOptions(): MapOptions & { showUnchanged: boolean } {
  const defaults: MapOptions & { showUnchanged: boolean } = { scope: "changed", showTests: false, showUnchanged: false };
  try {
    return { ...defaults, ...JSON.parse(localStorage.getItem(OPTIONS_KEY) ?? "{}") };
  } catch {
    return defaults;
  }
}

/** Which review a report belongs to. Refined reports of one review share it; another review does not. */
const reviewKey = (r: ChangeReport) => `${r.repo.root}\u0000${r.repo.baseSha}\u0000${r.repo.headSha}`;

export function App() {
  const [job, setJob] = useState<JobState | null>(null);
  const [report, setReport] = useState<ChangeReport | null>(null);
  /** The comparison report, with every reference matched by name. Asked for on demand. */
  const [byName, setByName] = useState<ChangeReport | null>(null);
  const [variant, setVariant] = useState<"indexed" | "name-based">("indexed");
  const [comparing, setComparing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [starting, setStarting] = useState(false);
  const jobId = useRef(0);
  const shownKey = useRef("");
  /** Reports are applied one at a time, in the order they arrive. */
  const applying = useRef<Promise<void>>(Promise.resolve());

  // A report of the review on screen replaces what is shown; the first report of another review also
  // loads that review's marks and notes, forgets its cached sources, and forgets the focus of the previous
  // one. Loading the marks waits, so later reports queue behind it: a preliminary report must never
  // replace a refined one that arrived during the wait. A report of a job that has since been replaced
  // is dropped.
  const show = useCallback((raw: ChangeReport): Promise<void> => {
    const job = jobId.current;
    const apply = async () => {
      if (job !== jobId.current) return;
      const next = validate(raw);
      const key = reviewKey(next);
      if (key !== shownKey.current) {
        if (shownKey.current) history.replaceState(null, "", location.pathname + location.search);
        shownKey.current = key;
        forgetSources();
        await initReview(next);
        if (job !== jobId.current) return;
      }
      setReport(next);
    };
    const run = applying.current.then(apply);
    applying.current = run.catch(() => undefined);
    return run;
  }, []);

  useEffect(() => {
    let stop: (() => void) | undefined;
    let alive = true;
    const onEvent = (e: ReviewEvent) => {
      if (!alive) return;
      if (e.type === "started") {
        jobId.current = e.job.id;
        setJob(e.job);
        setReport(null);
        setByName(null);
        setVariant("indexed");
        setError(null);
        setStarting(false);
        return;
      }
      if (e.jobId !== jobId.current) return;
      if (e.type === "progress") setJob((j) => (j ? { ...j, message: e.message } : j));
      else if (e.type === "report") void show(e.report);
      else if (e.type === "finished") setJob((j) => (j ? { ...j, running: false, cancelled: e.cancelled, message: "" } : j));
      else if (e.type === "failed") {
        setJob((j) => (j ? { ...j, running: false, error: e.error, message: "" } : j));
        setError(e.error);
      }
    };
    // Listen first, then ask for the state, so nothing sent in between is lost.
    backend
      .onReviewEvent(onEvent)
      .then((un) => {
        stop = un;
        return backend.currentState();
      })
      .then(async (state) => {
        if (!alive) return;
        resetSources(state.editor ?? null);
        if (state.job) {
          jobId.current = state.job.id;
          setJob(state.job);
          if (state.job.error) setError(state.job.error);
        }
        if (state.report) await show(state.report);
      })
      .catch((e) => setError(String(e?.message ?? e)))
      .finally(() => alive && setReady(true));
    return () => {
      alive = false;
      stop?.();
    };
  }, [show]);

  const start = useCallback((request: ReviewRequest) => {
    setError(null);
    setStarting(true);
    backend.startReview(request).catch((e) => {
      setStarting(false);
      setError(String(e?.message ?? e));
    });
  }, []);

  const compare = useCallback(
    (v: "indexed" | "name-based") => {
      setVariant(v);
      if (v !== "name-based" || byName) return;
      setComparing(true);
      backend
        .nameBasedReport()
        .then((r) => setByName(validate(r)))
        .catch((e) => {
          setVariant("indexed");
          setError(String(e?.message ?? e));
        })
        .finally(() => setComparing(false));
    },
    [byName],
  );

  const newReview = useCallback(() => {
    shownKey.current = "";
    history.replaceState(null, "", location.pathname + location.search);
    setReport(null);
    setByName(null);
    setVariant("indexed");
  }, []);

  // The menu bar's File → New Review…, File → Export Notes…, Edit → Copy Notes as Markdown and View → Show
  // Name-Matched Comparison (app/src-tauri/src/menu.rs): the app is told when they can be used and whether
  // the comparison is on screen, and sends their clicks. The notes stay loaded after New Review…, so the
  // notes items also need a review on screen.
  const { notes } = useReview();
  const running = !!job?.running || starting;
  const nameBased = variant === "name-based" && !!byName;
  const hasNotes = !!report && Object.keys(notes).length > 0;
  const menu = { canStartNew: !!report && !running, canCompare: !!report && !running && !comparing, nameBased, hasNotes };
  useEffect(() => {
    backend.setMenuState(menu).catch((e) => backend.logUiError(`menu state: ${e?.message ?? e}`));
  }, [menu.canStartNew, menu.canCompare, menu.nameBased, menu.hasNotes]); // eslint-disable-line react-hooks/exhaustive-deps
  const onMenu = useRef<(id: string) => void>(() => undefined);
  onMenu.current = (id) => {
    if (id === "new-review" && menu.canStartNew) newReview();
    else if (id === "compare-name-based" && menu.canCompare) compare(variant === "name-based" ? "indexed" : "name-based");
    // File → Export Notes… and Edit → Copy Notes as Markdown.
    else if (menu.hasNotes && notesMenuAction(id, notes)) return;
    // An ignored click: macOS has flipped the check mark already, so put it back.
    else backend.setMenuState(menu).catch(() => undefined);
  };
  useEffect(() => {
    let stop: (() => void) | undefined;
    let alive = true;
    backend
      .onMenu((id) => onMenu.current(id))
      .then((un) => (alive ? (stop = un) : un()))
      .catch((e) => backend.logUiError(`menu events: ${e?.message ?? e}`));
    return () => {
      alive = false;
      stop?.();
    };
  }, []);

  if (!ready) return <div className="empty">Starting…</div>;
  if (!report) return <StartScreen job={job} starting={starting} error={error} onStart={start} onCancel={() => void backend.cancelReview()} />;
  const shown = variant === "name-based" && byName ? byName : report;
  return (
    <Viewer
      key={reviewKey(report)}
      report={shown}
      status={
        <>
          <StatusBar job={job} report={report} error={error} onCancel={() => void backend.cancelReview()} />
          {nameBased && <ComparisonBanner onBack={() => compare("indexed")} />}
        </>
      }
    />
  );
}

function Viewer({ report, status }: { report: ChangeReport; status: ReactNode }) {
  const [llm, setLLMState] = useState(readLLM);
  const index = useMemo(() => buildIndex(report, { llm }), [report, llm]);
  const [opts, setOpts] = useState(readOptions);
  const setLLM = useCallback((on: boolean) => {
    setLLMState(on);
    try {
      localStorage.setItem(LLM_KEY, on ? "on" : "off");
    } catch {
      /* storage unavailable: the choice just doesn't persist */
    }
  }, []);
  const { reviewed, notes } = useReview();
  const [focusState, setFocusState] = useState<Focus>(readFocus);
  // Components whose unchanged neighbors were added to the map, and groups drawn as one node.
  const [expandedState, setExpanded] = useState<Set<string>>(() => new Set());
  const [collapsedState, setCollapsed] = useState(() => revealFocus(index, defaultCollapsed(index, visible(index, opts)), focusState));
  const scopeKey = `${opts.scope}|${opts.showTests}`;
  const [last, setLast] = useState({ index, scopeKey });
  let focus = focusState;
  let expanded = expandedState;
  let collapsed = collapsedState;
  if (last.index !== index || last.scopeKey !== scopeKey) {
    // Adjusting state during render, so nothing is drawn with the state of another report or scope.
    // A refined report can cut the code into other components (Bazel packages become targets): the focus
    // follows to where its code is now, and the groups and expansions, which are component ids, start
    // over. They also start over when the scope or the test filter changes.
    if (last.index !== index) focus = carryFocus(last.index, index, focusState);
    if (last.scopeKey !== scopeKey || !sameComponents(last.index, index)) {
      expanded = new Set();
      collapsed = revealFocus(index, defaultCollapsed(index, visible(index, opts)), focus);
      setExpanded(expanded);
      setCollapsed(collapsed);
    }
    if (focus !== focusState) setFocusState(focus);
    setLast({ index, scopeKey });
  }

  // A focus that was carried over to a refined report replaces the one in the URL.
  useEffect(() => {
    const hash = focusToHash(focus);
    if (location.hash.slice(1) !== hash) history.replaceState(null, "", hash ? `#${hash}` : location.pathname + location.search);
  }, [focus]);

  useEffect(() => {
    try {
      localStorage.setItem(OPTIONS_KEY, JSON.stringify(opts));
    } catch {
      /* storage unavailable: options just don't persist */
    }
  }, [opts]);

  useEffect(() => {
    const onPop = () => setFocusState(readFocus());
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  const setFocus = useCallback((f: Focus) => {
    const changesPage = levelOf(f) > 1 || levelOf(readFocus()) > 1;
    writeFocus(f);
    setFocusState(f);
    // A region focus scrolls to the region once its code is shown.
    if (changesPage && !(f?.type === "reviewItem" && f.region)) document.querySelector(".page")?.scrollTo(0, 0);
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable)) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      // Next and previous region in risk order, from anywhere.
      if (e.key === "j" || e.key === "]" || e.key === "k" || e.key === "[") {
        const next = e.key === "j" || e.key === "]" ? nextRegion(index, reviewed, readFocus()) : stepRegion(index, readFocus(), -1);
        if (JSON.stringify(next) !== JSON.stringify(readFocus())) setFocus(next);
        return;
      }
      if (e.key !== "Escape") return;
      const f = readFocus();
      // A code location has no parent of its own; go back to where it was opened from.
      if (f?.type === "location") history.back();
      else setFocus(parentFocus(index, f));
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [setFocus, index, reviewed]);

  const vis = useMemo(() => visible(index, opts, expanded), [index, opts.scope, opts.showTests, expanded]); // eslint-disable-line react-hooks/exhaustive-deps
  // A focus inside a collapsed group opens the group, so the map shows it.
  useEffect(() => setCollapsed((c) => revealFocus(index, c, focus)), [index, focus]);
  const graph = useMemo(() => collapse(index, vis, collapsed), [index, vis, collapsed]);
  const groups = useMemo(() => [...vis.nodes].filter((id) => isGroupOf(index, vis, id)), [index, vis]);
  const toggleGroup = useCallback(
    (id: string) =>
      setCollapsed((c) => {
        const next = new Set(c);
        if (!next.delete(id)) next.add(id);
        return next;
      }),
    [],
  );
  const toggleNeighbors = useCallback(
    (id: string) =>
      setExpanded((x) => {
        const next = new Set(x);
        if (!next.delete(id)) next.add(id);
        return next;
      }),
    [],
  );

  const level = levelOf(focus);
  const trail = crumbs(index, focus);
  // On the map, tapping the selected component again opens its interface view.
  const onMapFocus = useCallback(
    (f: Focus) => {
      if (f?.type === "component" && focus?.type === "component" && focus.id === f.id && index.components.get(f.id)?.kind !== "external") {
        setFocus({ type: "interface", id: f.id });
      } else setFocus(f);
    },
    [focus, index, setFocus],
  );

  const short = (s: string) => s.slice(0, 7);
  return (
    <div className="app">
      <header className="topbar">
        <nav className="crumbs">
          <button className="icon" title="Back" onClick={() => history.back()}>
            ‹
          </button>
          <button className="icon" title="Forward" onClick={() => history.forward()}>
            ›
          </button>
          <button className={`crumb ${focus ? "" : "current"}`} onClick={() => setFocus(level > 1 ? mapFocus(index, focus) : null)}>
            Map
          </button>
          {trail.map((c, i) => (
            <span key={i} className="crumb-part">
              <span className="sep">›</span>
              {c.focus ? (
                <button className="crumb" onClick={() => setFocus(c.focus!)}>
                  {c.label}
                </button>
              ) : (
                <span className="crumb current">{c.label}</span>
              )}
            </span>
          ))}
        </nav>
        <div className="repo muted" title={`${report.repo.root}\nbase ${report.repo.baseSha}\nhead ${report.repo.headSha}`}>
          {report.repo.base || short(report.repo.baseSha)} → {report.repo.head || short(report.repo.headSha)}
        </div>
        <div className="toggles" hidden={level > 1}>
          <label>
            Show
            <select value={opts.scope} onChange={(e) => setOpts({ ...opts, scope: e.target.value as MapOptions["scope"] })}>
              <option value="changed">Changed components</option>
              <option value="neighbors">Changed and neighbors</option>
              <option value="all">Whole system</option>
            </select>
          </label>
          <label>
            <input type="checkbox" checked={opts.showTests} onChange={(e) => setOpts({ ...opts, showTests: e.target.checked })} />
            Tests
          </label>
          <label>
            <input type="checkbox" checked={opts.showUnchanged} onChange={(e) => setOpts({ ...opts, showUnchanged: e.target.checked })} />
            Unchanged edges
          </label>
          {groups.length > 0 && (
            <button className="link" onClick={() => setCollapsed(graph.collapsed.size > 0 ? new Set() : revealFocus(index, new Set(groups), focus))}>
              {graph.collapsed.size > 0 ? "Expand groups" : "Collapse groups"}
            </button>
          )}
        </div>
        <div className="toolbar-end">
          <NotesButton notes={notes} regions={index.regions} setFocus={setFocus} />
          <NextControl index={index} focus={focus} setFocus={setFocus} />
        </div>
      </header>
      {status}
      <main className={`body ${level > 1 ? "paged" : ""}`}>
        <section className="map">
          <MapView index={index} graph={graph} focus={focus} setFocus={onMapFocus} showUnchanged={opts.showUnchanged} toggleGroup={toggleGroup} />
          {(vis.hiddenUnrelated > 0 || vis.hiddenTests > 0) && (
            <div className="hidden-note">
              {vis.hiddenUnrelated > 0 && (
                <button className="link" onClick={() => setOpts({ ...opts, scope: opts.scope === "changed" ? "neighbors" : "all" })}>
                  {vis.hiddenUnrelated} unchanged component{vis.hiddenUnrelated === 1 ? "" : "s"} hidden
                </button>
              )}
              {vis.hiddenTests > 0 && (
                <button className="link" onClick={() => setOpts({ ...opts, showTests: true })}>
                  {vis.hiddenTests} test component{vis.hiddenTests === 1 ? "" : "s"} hidden
                </button>
              )}
            </div>
          )}
        </section>
        <Sidebar
          index={index}
          focus={focus}
          setFocus={setFocus}
          setLLM={setLLM}
          map={{ vis, graph, showTests: opts.showTests, expanded, toggleNeighbors, toggleGroup }}
        />
        {level > 1 && (
          <div className="page">
            {focus?.type === "interface" && <InterfacePage index={index} id={focus.id} go={setFocus} />}
            {focus?.type === "reviewItem" && <ReviewItemPage index={index} id={focus.id} region={focus.region} go={setFocus} />}
            {focus?.type === "location" && <LocationPage index={index} side={focus.side} file={focus.file} line={focus.line} go={setFocus} />}
          </div>
        )}
      </main>
    </div>
  );
}
