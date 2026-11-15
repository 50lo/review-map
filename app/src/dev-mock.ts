// A stand-in for the app's Rust side, for working on the UI in a plain browser with `bazel run //app:dev`.
// It answers the commands in backend.ts from the dev server (see vite.config.ts): the report named by
// REVIEWMAP_REPORT, sources read with `git show`, and marks kept in browser storage. Never part of the app.

import { mockIPC } from "@tauri-apps/api/mocks";

export async function install(): Promise<void> {
  const res = await fetch("/__dev/report", { cache: "no-store" });
  const report = res.ok ? await res.json() : null;
  const reviewKey = (a: { root: string; head: string; headSha: string }) => `reviewmap.dev.review.${a.root}.${a.head}.${a.headSha}`;
  mockIPC(
    async (cmd, payload) => {
      const args = (payload ?? {}) as Record<string, unknown>;
      switch (cmd) {
        case "current_state":
          return report
            ? {
                job: { id: 1, request: { repo: report.repo.root, base: report.repo.base, head: report.repo.head, useMergeBase: true, targets: [], bazelArgs: [] }, running: false, message: "", cancelled: false },
                report,
                editor: null,
              }
            : { editor: null };
        case "name_based_report":
          return report;
        case "read_source": {
          const r = await fetch(`/__dev/source?side=${args.side}&file=${encodeURIComponent(String(args.file))}`);
          return r.ok ? await r.text() : null;
        }
        case "load_review_state":
          return JSON.parse(localStorage.getItem(reviewKey(args as never)) ?? "null");
        case "save_review_state":
          localStorage.setItem(reviewKey(args as never), JSON.stringify(args.state));
          return null;
        case "recent_reviews":
          return [];
        case "log_ui_error":
          console.error("ui error:", args.message);
          return null;
        case "repo_defaults":
          throw new Error("The dev preview has no repository access.");
        case "start_review":
          throw new Error("The dev preview can't start a review. Set REVIEWMAP_REPORT to a report written by `reviewmap --report`.");
        default:
          return null;
      }
    },
    { shouldMockEvents: true },
  );
}
