// The bridge to the app's Rust side (app/src-tauri). The UI never talks HTTP: it invokes commands and
// listens to one event stream.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { ChangeReport, Side } from "./types";

/** What to review. Mirrors `ReviewRequest` in crates/core/src/session.rs. */
export interface ReviewRequest {
  repo: string;
  base: string;
  /** Empty means the branch checked out in the repository. */
  head?: string;
  useMergeBase: boolean;
  /** Where `reviewmap` was run; the Bazel workspace around it is the one explicit targets belong to. */
  cwd?: string;
  targets: string[];
  bazelArgs: string[];
  /** False shows only links that syntax proves; undefined follows reviewmap.yml and is otherwise on. */
  index?: boolean;
}

export interface JobState {
  id: number;
  request: ReviewRequest;
  running: boolean;
  /** The latest progress line. */
  message: string;
  cancelled: boolean;
  error?: string;
}

export interface AppState {
  job?: JobState;
  report?: ChangeReport;
  /** The editor that Open uses, or null when none is set. */
  editor?: string | null;
}

export type ReviewEvent =
  | { type: "started"; job: JobState }
  | { type: "progress"; jobId: number; message: string }
  | { type: "report"; jobId: number; report: ChangeReport }
  | { type: "finished"; jobId: number; cancelled: boolean }
  | { type: "failed"; jobId: number; error: string };

export interface RecentReview {
  repo: string;
  base: string;
  head?: string;
  targets: string[];
  bazelArgs: string[];
}

export interface RepoDefaults {
  root: string;
  branch: string;
}

export const currentState = () => invoke<AppState>("current_state");
export const startReview = (request: ReviewRequest) => invoke<number>("start_review", { request });
export const cancelReview = () => invoke<void>("cancel_review");
export const nameBasedReport = () => invoke<ChangeReport>("name_based_report");
export const readSource = (side: Side, file: string) => invoke<string | null>("read_source", { side, file });
export const openInEditor = (file: string, line: number) => invoke<string>("open_in_editor", { file, line });
export const loadReviewState = (root: string, head: string, headSha: string) => invoke<unknown>("load_review_state", { root, head, headSha });
export const saveReviewState = (root: string, head: string, headSha: string, state: unknown) =>
  invoke<void>("save_review_state", { root, head, headSha, state });
export const recentReviews = () => invoke<RecentReview[]>("recent_reviews");
export const repoDefaults = (path: string) => invoke<RepoDefaults>("repo_defaults", { path });

/** Writes a failure in the UI to the app log. Never throws: it is called while something else is failing. */
export const logUiError = (message: string) => invoke<void>("log_ui_error", { message }).catch(() => undefined);

/** What the menu bar's own items can do now. Mirrors `MenuState` in app/src-tauri/src/menu.rs. */
export interface MenuState {
  /** File → New Review… is enabled. */
  canStartNew: boolean;
  /** View → Show Name-Matched Comparison is enabled. */
  canCompare: boolean;
  /** The comparison report is on screen: the comparison item's check mark. */
  nameBased: boolean;
}

export const setMenuState = (state: MenuState) => invoke<void>("set_menu_state", { state });

/** Calls `cb` with the id of a menu bar item when it is chosen. */
export function onMenu(cb: (id: string) => void): Promise<() => void> {
  return listen<{ id: string }>("menu", (e) => cb(e.payload.id));
}

export function onReviewEvent(handler: (e: ReviewEvent) => void): Promise<() => void> {
  return listen<ReviewEvent>("review://event", (e) => handler(e.payload));
}

/** Asks for a folder with the system's dialog. Null when the dialog was dismissed. */
export async function chooseFolder(): Promise<string | null> {
  const { open } = await import("@tauri-apps/plugin-dialog");
  const picked = await open({ directory: true, multiple: false, title: "Choose a repository" });
  return typeof picked === "string" ? picked : null;
}
