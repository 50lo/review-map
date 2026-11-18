#!/usr/bin/env python3
"""Turns benchmark logs into the phase table of docs/rebuild-step5-speed.md ("Results").

    scripts/bench-phases.py <run dir or log.txt>...

Each argument is a directory that scripts/bench-review.sh wrote (log.txt, summary.txt) or a log.txt itself.
Prints one markdown row per run: seconds of wall time per phase, from the core's `[timing]` lines (their format
is described in docs/rebuild-build.md, "Benchmarking a review"). Steps of one phase can run at the same time
(the graph queries and index builds of different workspaces and sides, since rm-zm5r), so a phase's time is the
wall time its lines cover, not their sum; for a log without timestamps it is the sum. A dash means the phase
didn't run, or its result came from Review Map's cache. Below the table, how much of each run's wall time the
timing lines cover.
"""
import os
import re
import sys

COLUMNS = ["parse", "graph", "Swift build", "Swift read", "TS Bazel", "scip-ts", "Kotlin Bazel", "Kotlin indexer", "download", "reports"]
TIMING = re.compile(r"\[timing\] ([0-9.]+)s (.*)$")
STAMP = re.compile(r"\s*([0-9]+(?:\.[0-9]+)?) ")


def column(label):
    """The column a timing line adds to, or None. Each column takes lines that don't nest in one another."""
    if label.startswith("parse "):
        return "parse"
    if label.startswith("graph "):
        return "graph"
    if label.startswith("swift helper read"):
        return "Swift read"
    if label.startswith("report build"):
        return "reports"
    if label.startswith("cmd bazel build (swift index"):
        return "Swift build"
    if label.startswith("cmd bazel build (typescript index"):
        return "TS Bazel"
    if label.startswith("cmd bazel build (kotlin index"):
        return "Kotlin Bazel"
    if label.startswith("cmd ") and "(scip-typescript" in label:
        return "scip-ts"
    if label.startswith("cmd curl"):
        return "download"
    if label.startswith("index kotlin "):
        return "Kotlin index"
    return None


def union(intervals):
    """The length of the time the intervals cover together."""
    covered = 0.0
    end = None
    for a, b in sorted(intervals):
        a = max(a, 0.0)
        if end is None or a > end:
            covered += b - a
            end = b
        elif b > end:
            covered += b - end
            end = b
    return covered


def read_run(path):
    log = os.path.join(path, "log.txt") if os.path.isdir(path) else path
    directory = os.path.dirname(os.path.abspath(log))
    phases = {c: 0.0 for c in COLUMNS}
    kotlin_index = 0.0
    # Per column: the interval of each line, when the log has timestamps.
    spans = {c: [] for c in COLUMNS + ["Kotlin index"]}
    stamped = True
    graph_report = None
    intervals = []
    last = 0.0
    with open(log, errors="replace") as f:
        for line in f:
            stamp = STAMP.match(line)
            t = float(stamp.group(1)) if stamp else None
            if t is not None:
                last = t
            if graph_report is None and t is not None and line[stamp.end():].startswith("Report: graph"):
                graph_report = t
            m = TIMING.search(line)
            if not m:
                continue
            seconds, label = float(m.group(1)), m.group(2).strip()
            if label.startswith("total"):
                continue
            c = column(label)
            if t is not None:
                intervals.append((t - seconds, t))
                if c:
                    spans[c].append((t - seconds, t))
            else:
                stamped = False
            if c == "Kotlin index":
                kotlin_index += seconds
            elif c:
                phases[c] += seconds
    if stamped:
        for c in COLUMNS:
            phases[c] = union(spans[c])
        kotlin_index = union(spans["Kotlin index"])
    # The Kotlin indexer's JVMs run several at a time: its wall time is the index step's, less its build and download.
    # An index step with no build is a cache hit or a workspace that doesn't build Kotlin: no indexer ran.
    if phases["Kotlin Bazel"]:
        phases["Kotlin indexer"] = max(0.0, kotlin_index - phases["Kotlin Bazel"] - phases["download"])

    summary = {}
    summary_path = os.path.join(directory, "summary.txt")
    if os.path.exists(summary_path):
        for line in open(summary_path):
            key, _, value = line.partition(": ")
            summary[key.strip()] = value.strip()
    total = float(summary["total"].split()[0]) if "total" in summary else last
    load = ""
    if "load at start" in summary and "load at end" in summary:
        first = lambda s: s.strip("{} ").split()[0]
        load = "%.0f→%.0f" % (float(first(summary["load at start"])), float(first(summary["load at end"])))

    # The share of wall time inside at least one timed step (steps nest and may run at the same time).
    covered = union(intervals)
    name = summary.get("run") or os.path.basename(directory)
    return {"name": name, "state": summary.get("state", ""), "phases": phases, "graph report": graph_report, "total": total, "load": load, "covered": covered}


def cell(value):
    return "%.1f" % value if value else "–"


def main(args):
    if not args or args[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if args else 2
    runs = [read_run(a) for a in args]
    header = ["Run", "state"] + COLUMNS + ["graph report at", "**total**", "load (1 min, start→end)"]
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for r in runs:
        cells = [r["name"], r["state"]] + [cell(r["phases"][c]) for c in COLUMNS]
        cells += [cell(r["graph report"]), "**%.1f**" % r["total"], r["load"]]
        print("| " + " | ".join(cells) + " |")
    print()
    for r in runs:
        share = 100 * r["covered"] / r["total"] if r["total"] else 0
        print("%s: timing lines cover %.1f of %.1f s (%.1f%%)" % (r["name"], r["covered"], r["total"], share))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
