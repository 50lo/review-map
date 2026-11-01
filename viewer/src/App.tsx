import { useCallback, useEffect, useMemo, useState } from "react";
import type { ChangeModel } from "./types";
import { buildIndex, edgeKey, visible, type Focus, type MapOptions } from "./graph";
import { loadFile, loadInitialModel } from "./load";
import { MapView } from "./MapView";
import { Sidebar } from "./Sidebar";

// Focus lives in the URL hash, so browser back/forward walk the focus history.
function readFocus(): Focus {
  const h = new URLSearchParams(location.hash.slice(1));
  const c = h.get("c");
  if (c) return { type: "component", id: c };
  const e = h.get("e");
  if (e) return { type: "edge", key: e };
  return null;
}

function writeFocus(f: Focus) {
  const hash = !f ? "" : f.type === "component" ? `c=${encodeURIComponent(f.id)}` : `e=${encodeURIComponent(f.key)}`;
  if (location.hash.slice(1) === hash) return;
  history.pushState(null, "", hash ? `#${hash}` : location.pathname + location.search);
}

const OPTIONS_KEY = "reviewmap.options.v2";

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
      .then(setModel)
      .catch((e) => setError(String(e?.message ?? e)))
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <div className="empty">Loading change model…</div>;
  if (!model) return <Picker error={error} onModel={setModel} onError={setError} />;
  return <Viewer model={model} />;
}

function Picker({ error, onModel, onError }: { error: string | null; onModel: (m: ChangeModel) => void; onError: (e: string) => void }) {
  const [over, setOver] = useState(false);
  const take = (f?: File) => f && loadFile(f).then(onModel, (e) => onError(String(e?.message ?? e)));
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
        Or run <code>reviewmap &lt;repo&gt; --base main --head feature --view</code> to analyze a change and open it here.
      </p>
      {error && <p className="error">{error}</p>}
    </div>
  );
}

function Viewer({ model }: { model: ChangeModel }) {
  const index = useMemo(() => buildIndex(model), [model]);
  const [opts, setOpts] = useState(readOptions);
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
    writeFocus(f);
    setFocusState(f);
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setFocus(null);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [setFocus]);

  const vis = useMemo(() => visible(index, opts), [index, opts.scope, opts.showTests]); // eslint-disable-line react-hooks/exhaustive-deps

  // A focus that the current filters hide (e.g. a test component) still shows in the panel.
  const focusName =
    focus?.type === "component"
      ? (index.components.get(focus.id)?.name ?? focus.id)
      : focus?.type === "edge"
        ? (() => {
            const e = model.edges.find((x) => edgeKey(x) === focus.key);
            return e ? `${index.components.get(e.from)?.name ?? e.from} → ${index.components.get(e.to)?.name ?? e.to}` : focus.key;
          })()
        : null;

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
          <button className={`crumb ${focus ? "" : "current"}`} onClick={() => setFocus(null)}>
            Map
          </button>
          {focusName && (
            <>
              <span className="sep">›</span>
              <span className="crumb current">{focusName}</span>
            </>
          )}
        </nav>
        <div className="repo muted" title={`${model.repo.root}\nbase ${model.repo.baseSha}\nhead ${model.repo.headSha}`}>
          {model.repo.base || short(model.repo.baseSha)} → {model.repo.head || short(model.repo.headSha)}
        </div>
        <div className="toggles">
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
          <MapView index={index} vis={vis} focus={focus} setFocus={setFocus} showUnchanged={opts.showUnchanged} />
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
        <Sidebar index={index} focus={focus} setFocus={setFocus} />
      </main>
    </div>
  );
}
