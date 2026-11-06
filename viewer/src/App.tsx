import { useCallback, useEffect, useMemo, useState } from "react";
import type { ChangeReport } from "./types";
import { buildIndex, collapse, defaultCollapsed, edgeKey, isGroupOf, mapFocus, revealFocus, stepRegion, visible, type Index, type MapOptions } from "./graph";
import { lastName } from "./levels";
import { loadFile, loadInitialReport } from "./load";
import { MapView } from "./MapView";
import { focusToHash, hashToFocus, levelOf, type Focus } from "./nav";
import { ReviewItemPage, InterfacePage, LocationPage } from "./Pages";
import { initReview } from "./review";
import { Sidebar } from "./Sidebar";

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

export function App() {
  const [report, setReport] = useState<ChangeReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadInitialReport()
      .then(async (m) => {
        if (m) await initReview(m);
        setReport(m);
      })
      .catch((e) => setError(String(e?.message ?? e)))
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <div className="empty">Loading change report…</div>;
  if (!report) return <Picker error={error} onReport={setReport} onError={setError} />;
  return <Viewer report={report} />;
}

function Picker({ error, onReport, onError }: { error: string | null; onReport: (m: ChangeReport) => void; onError: (e: string) => void }) {
  const [over, setOver] = useState(false);
  const take = (f?: File) =>
    f &&
    loadFile(f).then(
      async (m) => {
        await initReview(m);
        onReport(m);
      },
      (e) => onError(String(e?.message ?? e)),
    );
  return (
    <div
      className={`empty picker ${over ? "over" : ""}`}
      onDragOver={(e) => {
        e.preventDefault();
        setOver(true);
      }}
      onDragLeave={() => setOver(false)}
      onDrop={(e) => {
        e.preventDefault();
        setOver(false);
        take(e.dataTransfer.files[0]);
      }}
    >
      <h1>Review Map</h1>
      <p>Drop a change-report.json here, or choose one.</p>
      <input type="file" accept=".json,application/json" onChange={(e) => take(e.target.files?.[0])} />
      <p className="muted">
        Or run <code>reviewmap</code> in a repo to review its current branch against main here.
      </p>
      {error && <p className="error">{error}</p>}
    </div>
  );
}

function Viewer({ report }: { report: ChangeReport }) {
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
  const [focus, setFocusState] = useState<Focus>(readFocus);

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
        const next = stepRegion(index, readFocus(), e.key === "j" || e.key === "]" ? 1 : -1);
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
  }, [setFocus, index]);

  // Components whose unchanged neighbors were added to the map, and groups drawn as one node.
  // Both start over when the scope or the test filter changes.
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const vis = useMemo(() => visible(index, opts, expanded), [index, opts.scope, opts.showTests, expanded]); // eslint-disable-line react-hooks/exhaustive-deps
  const [collapsed, setCollapsed] = useState(() => revealFocus(index, defaultCollapsed(index, vis), focus));
  const scopeKey = `${opts.scope}|${opts.showTests}`;
  const [lastScope, setLastScope] = useState(scopeKey);
  if (scopeKey !== lastScope) {
    // Adjusting state during render, so the map never draws the new scope with the old groups.
    const base = visible(index, opts);
    setLastScope(scopeKey);
    setExpanded(new Set());
    setCollapsed(revealFocus(index, defaultCollapsed(index, base), focus));
  }
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
      </header>
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
