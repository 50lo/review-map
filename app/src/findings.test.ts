import { describe, expect, it } from "vitest";
import { buildIndex } from "./graph";
import { edgeFindingView, findingFocus } from "./findings";
import { validate } from "./load";
import type { Component, Edge, ExternalDepChange, Finding } from "./types";

const comp = (id: string, name: string, kind = "bazelTarget"): Component => ({ id, name, kind, paths: [], changedReviewItems: 0, interfaceChanges: 0, changeScore: 0 });
const edge = (from: string, to: string, status: Edge["status"], refs: Edge["refs"] = []): Edge => ({ from, to, status, refs, symbolsAdded: refs.map((r) => r.symbol) });
const ref = (symbol: string, file: string, line: number) => ({ symbol, file, line, side: "head" as const });

function setup(opts: { edges: Edge[]; externalDeps?: ExternalDepChange[]; findings: Finding[]; components?: Component[] }) {
  const components = opts.components ?? [
    comp("//helper", "helper"),
    comp("//core", "Core"),
    comp("//cli", "CLI"),
    comp("//app", "App"),
    comp("//ui", "UI"),
    comp("//util", "Util"),
    comp("ext:swift-syntax", "swift-syntax", "external"),
  ];
  return buildIndex(validate({ components, edges: opts.edges, externalDeps: opts.externalDeps ?? [], findings: opts.findings }));
}

const helperEdge = edge("//helper", "ext:swift-syntax", "added", [ref("import SwiftSyntax", "helper/Sources/SwiftExtractor.swift", 3)]);

const newExternal = (users: Edge[], severity = "low"): Finding => ({
  id: "f-ext",
  source: "check",
  kind: "new-external",
  severity,
  message: "helper now depends on swift-syntax.",
  evidence: users.map((u) => `${u.from} → swift-syntax (import SwiftSyntax at x:1)`),
  anchors: [...users.map((u) => ({ from: u.from, to: u.to })), { component: "ext:swift-syntax" }],
});

describe("edgeFindingView: new-external", () => {
  it("is only a chip when the lockfile and other users add nothing", () => {
    const f = newExternal([helperEdge]);
    const index = setup({ edges: [helperEdge], findings: [f] });
    expect(edgeFindingView(index, helperEdge, f)).toEqual({ kind: "chip", finding: f });
    // The chip still leads where the finding leads.
    expect(findingFocus(index, f)).toEqual({ type: "edge", key: "//helper->ext:swift-syntax" });
  });

  it("says the package is new in the lockfile, with its version", () => {
    const f = newExternal([helperEdge], "medium");
    const index = setup({ edges: [helperEdge], externalDeps: [{ name: "swift-syntax", change: "added", to: "600.0.1" }], findings: [f] });
    expect(edgeFindingView(index, helperEdge, f)).toEqual({ kind: "line", finding: f, context: "New in the lockfile at 600.0.1" });
  });

  it("leaves the version out when the lockfile has none, and ignores entries that are not added", () => {
    const f = newExternal([helperEdge], "medium");
    const noVersion = setup({ edges: [helperEdge], externalDeps: [{ name: "swift-syntax", change: "added" }], findings: [f] });
    expect(edgeFindingView(noVersion, helperEdge, f)).toMatchObject({ kind: "line", context: "New in the lockfile" });
    const bumped = setup({ edges: [helperEdge], externalDeps: [{ name: "swift-syntax", change: "bumped", from: "1", to: "2" }], findings: [f] });
    expect(edgeFindingView(bumped, helperEdge, f)).toEqual({ kind: "chip", finding: f });
  });

  it("names the other components that newly use the package, after the lockfile", () => {
    const core = edge("//core", "ext:swift-syntax", "added", [ref("import SwiftSyntax", "core/A.swift", 1)]);
    const cli = edge("//cli", "ext:swift-syntax", "added", [ref("import SwiftSyntax", "cli/B.swift", 1)]);
    // An unchanged link into the package is not a new user.
    const old = edge("//app", "ext:swift-syntax", "unchanged", [ref("import SwiftSyntax", "app/C.swift", 1)]);
    const f = newExternal([cli, core, helperEdge], "medium");
    const index = setup({ edges: [core, cli, helperEdge, old], externalDeps: [{ name: "swift-syntax", change: "added", to: "600.0.1" }], findings: [f] });
    expect(edgeFindingView(index, core, f)).toEqual({ kind: "line", finding: f, context: "New in the lockfile at 600.0.1 · also new in CLI, helper" });
  });

  it("shows at most three other users, then how many more", () => {
    const froms = ["//helper", "//cli", "//app", "//ui", "//util"];
    const users = froms.map((from) => edge(from, "ext:swift-syntax", "added", [ref("import SwiftSyntax", `${from}/X.swift`, 1)]));
    const core = edge("//core", "ext:swift-syntax", "added", [ref("import SwiftSyntax", "core/A.swift", 1)]);
    const f = newExternal([core, ...users]);
    const index = setup({ edges: [core, ...users], findings: [f] });
    expect(edgeFindingView(index, core, f)).toEqual({ kind: "line", finding: f, context: "also new in helper, CLI, App and 2 more" });
  });
});

describe("edgeFindingView: layering", () => {
  const e = edge("//core", "//ui", "added", [ref("Button", "core/A.swift", 12), ref("ui_lib", "core/BUILD.bazel", 0)]);
  const other = edge("//util", "//ui", "added", [ref("Label", "util/U.swift", 4)]);
  const f: Finding = {
    id: "f-layer",
    source: "check",
    kind: "layering",
    severity: "high",
    message: "Core (domain) depends on UI (ui), against the declared layering.",
    evidence: [
      "Core is in domain, UI is in ui, which sits above it in reviewmap.yml.",
      "Button at core/A.swift:12",
      "ui_lib in core/BUILD.bazel",
      // A reference of another link in the same finding stays: this panel doesn't list it.
      "Label at util/U.swift:4",
    ],
    suggestion: "Move the code that needs UI up into ui, or pass what it needs down through an interface in domain.",
    anchors: [{ from: "//core", to: "//ui" }, { from: "//util", to: "//ui" }, { component: "//core" }, { component: "//ui" }],
  };

  it("keeps the layer line and drops the references this panel lists, and anchors to the link and its ends", () => {
    const index = setup({ edges: [e, other], findings: [f] });
    expect(edgeFindingView(index, e, f)).toEqual({
      kind: "full",
      finding: f,
      evidence: ["Core is in domain, UI is in ui, which sits above it in reviewmap.yml.", "Label at util/U.swift:4"],
      anchors: [{ from: "//util", to: "//ui" }],
    });
  });

  it("does not drop a reference whose line only shares a suffix with this link's", () => {
    const near = { ...f, evidence: [f.evidence[0], "Button at core/A.swift:112", "Button at xcore/A.swift:12"] };
    const index = setup({ edges: [e, other], findings: [near] });
    expect(edgeFindingView(index, e, near)).toMatchObject({ kind: "full", evidence: near.evidence });
  });
});

describe("edgeFindingView: cycle and others", () => {
  it("keeps a cycle's evidence whole and drops only the anchors that are this link or its ends", () => {
    const e = edge("//core", "//cli", "added", [ref("run", "core/A.swift", 3)]);
    const back = edge("//cli", "//core", "unchanged", [ref("Model", "cli/B.swift", 7)]);
    const f: Finding = {
      id: "f-cycle",
      source: "check",
      kind: "cycle",
      severity: "high",
      message: "Core and CLI now depend on each other.",
      evidence: ["Core → CLI (run at core/A.swift:3)", "CLI → Core (Model at cli/B.swift:7)"],
      anchors: [{ from: "//core", to: "//cli" }, { from: "//cli", to: "//core" }, { component: "//core" }, { component: "//cli" }, { component: "//app" }],
    };
    const index = setup({ edges: [e, back], findings: [f] });
    expect(edgeFindingView(index, e, f)).toEqual({
      kind: "full",
      finding: f,
      evidence: f.evidence,
      anchors: [{ from: "//cli", to: "//core" }, { component: "//app" }],
    });
  });

  it("keeps an LLM finding whole apart from the anchors", () => {
    const e = edge("//core", "//cli", "added", [ref("run", "core/A.swift", 3)]);
    const f: Finding = {
      id: "f-llm",
      source: "llm",
      kind: "placement",
      severity: "medium",
      message: "This belongs elsewhere.",
      evidence: ["run at core/A.swift:3"],
      anchors: [{ from: "//core", to: "//cli" }, { reviewItem: "r1" }],
    };
    const index = setup({ edges: [e], findings: [f] });
    expect(edgeFindingView(index, e, f)).toEqual({ kind: "full", finding: f, evidence: f.evidence, anchors: [{ reviewItem: "r1" }] });
  });
});
