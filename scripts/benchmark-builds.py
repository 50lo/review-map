#!/usr/bin/env python3
"""Compare native SwiftPM and Bazel builds, with dependency downloads excluded."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import platform
import shlex
import statistics
import subprocess
import time


ROOT = Path(__file__).resolve().parent.parent


def capture(command):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--systems", nargs="+", choices=["spm", "bazel"], default=["spm", "bazel"])
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--runs", type=int, default=3, help="samples per warm-build scenario")
    parser.add_argument("--skip-clean", action="store_true", help="warm existing outputs, then measure only warm scenarios")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/experiment/benchmark.json")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be at least 1")
    if "bazel" in args.systems and platform.system() == "Darwin":
        check = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
        if check.returncode:
            parser.error("Bazel's Swift rules require full Xcode. Select it with DEVELOPER_DIR; "
                         "Command Line Tools alone cannot build this target.")

    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    lock_path = ROOT / ".build/experiment/benchmark.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock = lock_path.open("w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    results = {
        "configuration": args.configuration,
        "skip_clean": args.skip_clean,
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "commit": capture(["git", "rev-parse", "HEAD"]),
        "platform": platform.platform(),
        "machine": capture(["sysctl", "-n", "hw.model"]) if platform.system() == "Darwin" else platform.machine(),
        "cpus": os.cpu_count(),
        "swift": capture(["swift", "--version"]),
        "spm_build_system_default": next((line.strip() for line in capture(["swift", "build", "--help"]).splitlines()
                                          if "Specify the build system to use." in line), "unspecified"),
        "developer_dir": os.environ.get("DEVELOPER_DIR") or capture(["xcode-select", "-p"]),
        "toolchains": os.environ.get("TOOLCHAINS"),
        "samples": [],
    }
    if "bazel" in args.systems:
        results["bazel"] = capture(["bazel", "--version"])
    logs = args.output.parent / (args.output.stem + "-logs")
    logs.mkdir(exist_ok=True)

    def save():
        args.output.write_text(json.dumps(results, indent=2) + "\n")

    def run(command, label, measured=False):
        print(f"{label}: {shlex.join(map(str, command))}", flush=True)
        log = logs / (label + ".log")
        start = time.perf_counter()
        try:
            with log.open("w") as output:
                status = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT).returncode
        except KeyboardInterrupt:
            results["samples"].append({"scenario": label, "seconds": round(time.perf_counter() - start, 3),
                                       "exit_code": None, "status": "interrupted", "log": str(log)})
            save()
            raise SystemExit(f"Interrupted; partial results saved to {args.output}")
        elapsed = time.perf_counter() - start
        if measured or status:
            results["samples"].append({"scenario": label, "seconds": round(elapsed, 3),
                                       "exit_code": status, "command": list(map(str, command)), "log": str(log)})
            save()
        print(f"  {elapsed:.3f}s (exit {status})", flush=True)
        if status:
            raise SystemExit(f"Build failed; see {log}")

    # Change executable code so both systems must compile, rather than just touching a file.
    edits = [
        ("cli-edit", ROOT / "Sources/reviewmap/main.swift", 'msg + "\\n"', 'msg + " [benchmark {n}]\\n"'),
        ("core-edit", ROOT / "Sources/ReviewMapCore/ChangeModelIO.swift", '"Warnings: ', '"Warnings [benchmark {n}]: '),
    ]
    for _, path, old, _ in edits:
        if path.read_text().count(old) != 1:
            parser.error(f"benchmark edit anchor changed in {path}; update this script")

    for system in args.systems:
        if system == "spm":
            scratch = str(ROOT / f".build/benchmark-spm-{args.configuration}")
            package = ["swift", "package", "--scratch-path", scratch]
            run(package + ["resolve", "--force-resolved-versions"], "spm-resolve")
            if not args.skip_clean:
                run(package + ["clean"], "spm-clean")
            build = ["swift", "build", "--scratch-path", scratch, "--configuration",
                     args.configuration, "--product", "reviewmap", "--force-resolved-versions"]
        else:
            build = ["bazel", "build", "--compilation_mode=" + ("opt" if args.configuration == "release" else "dbg"),
                     "--disk_cache=", "--noremote_accept_cached", "//:reviewmap"]
            # First build warms downloads, generators and toolchain discovery, outside the comparison.
            run(build, "bazel-prepare")
            if not args.skip_clean:
                run(["bazel", "clean"], "bazel-clean")
        if args.skip_clean:
            if system == "spm":
                run(build, "spm-prepare")
        else:
            run(build, system + "-clean-build", measured=True)
        for n in range(1, args.runs + 1):
            run(build, f"{system}-no-op-{n}", measured=True)
        for label, path, old, replacement in edits:
            original = path.read_bytes()
            try:
                for n in range(1, args.runs + 1):
                    path.write_bytes(original.decode().replace(old, replacement.replace("{n}", str(n))).encode())
                    run(build, f"{system}-{label}-{n}", measured=True)
            finally:
                path.write_bytes(original)
            run(build, system + "-restore-" + label)

    print("\nMedian wall time (seconds):")
    for system in args.systems:
        for scenario in ["clean-build", "no-op", "cli-edit", "core-edit"]:
            times = [s["seconds"] for s in results["samples"]
                     if s["scenario"] == f"{system}-{scenario}" or s["scenario"].startswith(f"{system}-{scenario}-")]
            if times:
                print(f"  {system:5} {scenario:12} {statistics.median(times):8.3f}")
    print(f"\nResults: {args.output}")


if __name__ == "__main__":
    main()
