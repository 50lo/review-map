import React from "react";
import ReactDOM from "react-dom/client";
import "@xyflow/react/dist/style.css";
import "./styles.css";
import { App } from "./App";
import { logUiError } from "./backend";

const describe = (e: unknown) => (e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e));

/**
 * What the window shows when rendering fails, instead of going blank. The review itself lives in the app's
 * Rust side, so reloading the window brings back its latest report.
 */
class CrashScreen extends React.Component<{ children: React.ReactNode }, { error: unknown }> {
  state = { error: null as unknown };

  static getDerivedStateFromError(error: unknown) {
    return { error };
  }

  componentDidCatch(error: unknown, info: React.ErrorInfo) {
    void logUiError(`${describe(error)}\n${info.componentStack ?? ""}`);
  }

  render() {
    if (!this.state.error) return this.props.children;
    const error = this.state.error;
    return (
      <div className="empty crash">
        <h1>The window could not show this review</h1>
        <p className="muted">The analysis is not lost. Reloading shows its latest report again.</p>
        <button className="btn primary" onClick={() => location.reload()}>
          Reload
        </button>
        <pre className="crash-detail">{error instanceof Error ? error.message : String(error)}</pre>
      </div>
    );
  }
}

async function main() {
  // Outside the app (`bazel run //app:dev` in a browser), a mock answers for the Rust side.
  if (import.meta.env.DEV && !("__TAURI_INTERNALS__" in window)) await (await import("./dev-mock")).install();
  window.addEventListener("error", (e) => void logUiError(describe(e.error ?? e.message)));
  window.addEventListener("unhandledrejection", (e) => void logUiError(`unhandled rejection: ${describe(e.reason)}`));
  ReactDOM.createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <CrashScreen>
        <App />
      </CrashScreen>
    </React.StrictMode>,
  );
}

void main();
