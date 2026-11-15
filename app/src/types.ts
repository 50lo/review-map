// Mirrors crates/core/src/model.rs. Only the fields the viewer reads are listed;
// unknown fields are ignored, and optional ones may be missing.

export type EdgeStatus = "added" | "removed" | "changed" | "unchanged";
export type Side = "base" | "head";

export interface ChangeReport {
  version: number;
  /**
   * resolution: "index" (some language indexed), "preliminary" (a language still waits for its index),
   * "syntax" (no index and none to come: only links that syntax proves), or "name-based" (the comparison report).
   */
  analyzer?: { version: string; resolution: string; languages?: string[] };
  repo: { root: string; base: string; head: string; baseSha: string; headSha: string; usesMergeBase?: boolean };
  /** How far the analysis got and how each language was resolved. Missing in prototype reports. */
  analysis?: AnalysisInfo;
  components: Component[];
  edges: Edge[];
  externalDeps: ExternalDepChange[];
  reviewItems: ReviewItem[];
  regions: Region[];
  warnings: Warning[];
  /** Structural review: the deterministic checks' findings, then the LLM's. Missing before version 3. */
  findings: Finding[];
  /** Set when the LLM annotator ran. */
  llm?: {
    tool: string;
    model?: string;
    command?: string;
    promptVersion: string;
    batches: number;
    cached: number;
    failed: number;
    reviewNotes?: boolean;
    /** The structural review: ok, cached, rejected, or skipped. */
    review?: string;
    /** Where the change's description came from: file, pr, or commits. */
    description?: string;
  };
}

export interface AnalysisInfo {
  /** "preliminary" (syntax only), "graph" (components from Bazel), or "complete". */
  stage: string;
  /** "indexed" or "name-based" (the comparison report). */
  variant: string;
  languages: LanguageCoverage[];
  /** Languages that are compiled but not analyzed (Java, Objective-C). */
  gaps?: CoverageGap[];
  workspaces?: WorkspaceInfo[];
}

export interface LanguageCoverage {
  id: string;
  /**
   * "preliminary" (the index is still to come), "syntax" (final without an index: only links that syntax
   * proves), "index", or "name-based" (only in the comparison report).
   */
  resolution: string;
  files: number;
  indexedFiles: number;
  /** Why the language is not indexed. */
  note?: string;
  /** Checks that did not run because reference coverage is incomplete ("unused-api", "untested", …). */
  heldBack?: string[];
}

export interface CoverageGap {
  language: string;
  changedFiles: number;
  files: number;
  sample: string[];
}

export interface WorkspaceInfo {
  path: string;
  targets: string[];
  /** "explicit", "xcodeproj", or "all". */
  scope: string;
  /** "configured", "unconfigured", or "none". */
  graph: string;
}

/** A component, an edge (from and to), or a review item. */
export interface Anchor {
  component?: string;
  from?: string;
  to?: string;
  reviewItem?: string;
}

export interface Finding {
  id: string;
  /** "check" (deterministic) or "llm". */
  source: "check" | "llm" | string;
  /** Checks: cycle, layering, new-external, unused-api, orphaned, conformers, untested. LLM: intent, placement, missing, duplicate, complexity. */
  kind: string;
  severity: "high" | "medium" | "low" | string;
  message: string;
  evidence: string[];
  suggestion?: string;
  /** The first anchor is the main one. */
  anchors: Anchor[];
  /** The code it is about, when that is one declaration. */
  location?: Location;
}

export interface LLMSummary {
  summary: string;
}

/** Review and removed regions get risk; context regions get keep and rank. */
export interface RegionLLM {
  risk?: number;
  keep?: boolean;
  rank?: number;
}

export interface Component {
  id: string;
  name: string;
  kind: "bazelTarget" | "bazelPackage" | "folder" | "external" | string;
  layer?: string;
  module?: string;
  parent?: string;
  isTest?: boolean;
  paths: string[];
  status?: "added" | "removed" | string;
  changedReviewItems: number;
  interfaceChanges: number;
  changeScore: number;
  llm?: LLMSummary;
}

export interface Ref {
  file: string;
  line: number;
  symbol: string;
  side: Side;
}

export interface Edge {
  from: string;
  to: string;
  status: EdgeStatus;
  symbolsAdded?: string[];
  symbolsRemoved?: string[];
  refs: Ref[];
  refCount?: number;
}

export interface Location {
  file: string;
  startLine: number;
  endLine: number;
  side: Side;
}

export interface Usage {
  component: string;
  symbol: string;
  file: string;
  line: number;
  /** usedBy: the isolation the reference runs in, when known ("@MainActor", "actor CartStore", "nonisolated"). */
  isolation?: string;
  /** usedBy: "base" for a use only at base (a caller the change removed); missing at head. */
  side?: Side;
}

export interface ReviewItem {
  id: string;
  component: string;
  kind: string;
  qualifiedName: string;
  parent?: string;
  isInterface: boolean;
  change: "added" | "removed" | "signature" | "body" | "modifiers" | "cosmetic" | string;
  changes?: string[];
  signature: { base?: string; head?: string };
  /** Prefixed with the language: "swift:codable-shape". Version 1 reports have no prefix. */
  contractFlags: string[];
  tags?: string[];
  location: Location;
  baseLocation?: Location;
  usedBy?: Usage[];
  dependsOn?: Usage[];
  /** Added review items: existing declarations with similar names. */
  similar?: Usage[];
  llm?: LLMSummary;
}

export interface Region {
  id: string;
  reviewItem: string;
  kind: "review" | "context" | "removed" | string;
  file: string;
  startLine: number;
  endLine: number;
  side: Side;
  risk: number;
  reasons: string[];
  /** Context: the review regions it supports. */
  supports?: string[];
  /** Context: definition, caller, conformer, override, or state. */
  relation?: string;
  /** Context: the component the code belongs to. */
  component?: string;
  /** Context: the lines that matter. Missing means all of them. */
  lines?: number[];
  /** Removed regions inside a changed review item: the head line the removed code followed. */
  anchor?: number;
  llm?: RegionLLM;
}

export interface ExternalDepChange {
  name: string;
  change: "added" | "removed" | "bumped" | string;
  from?: string;
  to?: string;
}

export interface Warning {
  kind: string;
  message: string;
  file?: string;
  line?: number;
}
