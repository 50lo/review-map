import { useCallback, useEffect, useMemo, useState } from "react";
import type { ChangeModel } from "./types";
import { buildIndex, edgeKey, mapFocus, stepRegion, visible, type Index, type MapOptions } from "./graph";
import { lastName } from "./levels";
import { loadFile, loadInitialModel } from "./load";
import { MapView } from "./MapView";
import { focusToHash, hashToFocus, levelOf, type Focus } from "./nav";
import { EntityPage, InterfacePage, LocationPage } from "./Pages";
import { initReview } from "./review";
import { Sidebar } from "./Sidebar";

// Focus lives in the URL hash, so browser back/forward walk the focus history.
const readFocus = (): Focus => hashToFocus(location.hash);

function writeFocus(f: Focus) {
  const hash = focusToHash(f);
  if (location.hash.slice(1) === hash) return;
  history.pushState(null, "", hash ? `#${hash}` : location.pathname + location.search);
}

/** One level up: entity → its component's interface view → that component on the map → the map. */
function parentFocus(index: Index, f: Focus): Focus {
  if (!f) return null;
  if (f.type === "entity") {
    const e = index.entities.get(f.id);
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
      const e = index.model.edges.find((x) => edgeKey(x) === f.key);
      return [{ label: e ? `${name(e.from)} → ${name(e.to)}` : f.key }];
    }
    case "interface":
      return [{ label: name(f.id) }];
    case "entity": {
      const e = index.entities.get(f.id);
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
  const [model, setModel] = useState<ChangeModel | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadInitialModel()
      .then(async (m) => {
        if (m) await initReview(m);
        setModel(m);
      })
      .catch((e) => setError(String(e?.message ?? e)))
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <div className="empty">Loading change model…</div>;
  if (!model) return <Picker error={error} onModel={setModel} onError={setError} />;
  return <Viewer model={model} />;
}

function Picker({ error, onModel, onError }: { error: string | null; onModel: (m: ChangeModel) => void; onError: (e: string) => void }) {
  const [over, setOver] = useState(false);
  const take = (f?: File) =>
    f &&
    loadFile(f).then(
      async (m) => {
        await initReview(m);
        onModel(m);
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
      <p>Drop a change-model.json here, or choose one.</p>
      <input type="file" accept=".json,application/json" onChange={(e) => take(e.target.files?.[0])} />
      <p className="muted">
        Or run <code>reviewmap</code> in a repo to review its current branch against main here.
      </p>
      {error && <p className="error">{error}</p>}
    </div>
  );
}

function Viewer({ model }: { model: ChangeModel }) {
  const [llm, setLLMState] = useState(readLLM);
  const index = useMemo(() => buildIndex(model, { llm }), [model, llm]);
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
    if (changesPage && !(f?.type === "entity" && f.region)) document.querySelector(".page")?.scrollTo(0, 0);
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

  const vis = useMemo(() => visible(index, opts), [index, opts.scope, opts.showTests]); // eslint-disable-line react-hooks/exhaustive-deps

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
        <div className="repo muted" title={`${model.repo.root}\nbase ${model.repo.baseSha}\nhead ${model.repo.headSha}`}>
          {model.repo.base || short(model.repo.baseSha)} → {model.repo.head || short(model.repo.headSha)}
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
        </div>
      </header>
      <main className="body">
        <section className="map">
          <MapView index={index} vis={vis} focus={focus} setFocus={onMapFocus} showUnchanged={opts.showUnchanged} />
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
        <Sidebar index={index} focus={focus} setFocus={setFocus} setLLM={setLLM} />
        {level > 1 && (
          <div className="page">
            {focus?.type === "interface" && <InterfacePage index={index} id={focus.id} go={setFocus} />}
            {focus?.type === "entity" && <EntityPage index={index} id={focus.id} region={focus.region} go={setFocus} />}
            {focus?.type === "location" && <LocationPage index={index} side={focus.side} file={focus.file} line={focus.line} go={setFocus} />}
          </div>
        )}
      </main>
    </div>
  );
}
