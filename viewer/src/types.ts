// Mirrors Sources/ReviewMapCore/Model.swift. Only the fields the viewer reads are listed;
// unknown fields are ignored, and optional ones may be missing.

export type EdgeStatus = "added" | "removed" | "changed" | "unchanged";
export type Side = "base" | "head";

export interface ChangeModel {
  version: number;
  analyzer?: { version: string; resolution: string };
  repo: { root: string; base: string; head: string; baseSha: string; headSha: string; usesMergeBase?: boolean };
  components: Component[];
  edges: Edge[];
  externalDeps: ExternalDepChange[];
  entities: Entity[];
  regions: Region[];
  warnings: Warning[];
}

export interface Component {
  id: string;
  name: string;
  kind: "spmTarget" | "xcodeTarget" | "folder" | "external" | string;
  layer?: string;
  module?: string;
  parent?: string;
  isTest?: boolean;
  paths: string[];
  status?: "added" | "removed" | string;
  changedEntities: number;
  interfaceChanges: number;
  changeScore: number;
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
}

export interface Entity {
  id: string;
  component: string;
  kind: string;
  qualifiedName: string;
  parent?: string;
  isInterface: boolean;
  change: "added" | "removed" | "signature" | "body" | "modifiers" | "cosmetic" | string;
  changes?: string[];
  signature: { base?: string; head?: string };
  contractFlags: string[];
  tags?: string[];
  location: Location;
  baseLocation?: Location;
  usedBy?: Usage[];
  dependsOn?: Usage[];
}

export interface Region {
  id: string;
  entity: string;
  kind: "review" | "context" | "removed" | string;
  file: string;
  startLine: number;
  endLine: number;
  side: Side;
  risk: number;
  reasons: string[];
  llm?: { risk: number; note: string };
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
