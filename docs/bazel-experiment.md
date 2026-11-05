# Bazel build experiment

This branch adds a native Bazel build of the Swift analyzer alongside SwiftPM.
It uses `rules_swift` and `rules_swift_package_manager`: dependencies are compiled
by Bazel, rather than wrapping `swift build` in a Bazel action. `Package.swift`
and `Package.resolved` remain the source of dependency versions.

The installer, CI, SwiftPM tests and viewer build still use their existing commands.
The Bazel target covers the analyzer executable; it does not yet provide a Bazel
test target or build the viewer. Run `cd viewer && npm ci && npm run build` for the
viewer with either analyzer build system.

## Prerequisites and commands

- Bazelisk (uses the version pinned in `.bazelversion`).
- Full Xcode with Swift 6.2 or later. Command Line Tools alone work for SwiftPM,
  but the Bazel Swift toolchain requires an Xcode version and platform layout.
- macOS 14 or later. The initial experiment targets macOS; Linux is unverified.

If Xcode is installed outside the selected developer directory, set
`DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer` for **both** build systems.
This avoids changing the machine-wide `xcode-select` setting. Start a new Bazel
server with `bazel shutdown` after changing the selected toolchain.

```sh
bazel build --config=release //:reviewmap
bazel-bin/reviewmap --version
bazel run --config=release //:reviewmap -- --help
```

For viewer commands from a Bazel build, set `REVIEWMAP_VIEWER="$PWD/viewer"`.
The current viewer launcher locates its checkout from `#filePath`; Bazel source
paths are relative to its execution root.

## Repeatable comparison

Run builds serially on an otherwise idle machine, using the same developer
directory for both. Release is the primary comparison because
`scripts/install.sh` uses `swift build -c release --product reviewmap`.

```sh
python3 scripts/benchmark-builds.py --output .build/experiment/release.json
python3 scripts/benchmark-builds.py --configuration debug --output .build/experiment/debug.json
```

To measure one system independently:

```sh
python3 scripts/benchmark-builds.py --systems spm --output .build/experiment/spm-release.json
python3 scripts/benchmark-builds.py --systems bazel --output .build/experiment/bazel-release.json
```

The script measures wall time for:

1. One clean compilation, with dependency resolution/downloads outside the timer.
2. Three no-op builds.
3. Three changes to an executable-code string in the CLI module.
4. Three changes to an executable-code string in `ReviewMapCore`, including the
   resulting CLI rebuild/relink.

It restores the original source bytes in a `finally` block and rebuilds the
restored files outside the measurements. Avoid editing those two files during
the run. The SwiftPM scratch directory is dedicated to this benchmark. Bazel's
preparation build is excluded, then `bazel clean` removes compiled outputs;
disk-cache and remote-cache reads are disabled for measured Bazel builds. These
are warm-dependency, warm-OS-cache clean builds, not first-install measurements.
Each build system chooses its default local parallelism. A clean build has one
sample; the other scenarios report medians across three samples.

Results include commands, exit codes, toolchain/machine metadata and paths to
full logs. An unsuccessful build is saved as a failure and stops the script;
it must not be compared as a successful build time. The JSON and logs are in
the ignored `.build/experiment/` directory.

`--runs 1` reduces the warm scenarios to one sample each. `--skip-clean` runs
an untimed preparation build against existing outputs, then measures only warm
scenarios. This is useful for investigating toolchain settings without repeating
a clean compilation; report such settings separately from the default baseline.

## Initial machine check — 5 November 2026

- Base commit: `681efc8`.
- Mac mini (`Macmini9,1`), 8 logical CPUs; macOS 27.0.1, arm64; Apple Swift 6.4
  from `/Library/Developer/CommandLineTools`. `swift build --help` reports
  `swiftbuild` as its default backend; the baseline uses that default.
- Bazel 9.3.1; `rules_swift` 3.6.1; `rules_swift_package_manager` 1.25.0.
- `bazel mod tidy` and `bazel query 'deps(//:reviewmap)'` succeed.
- `bazel build --config=release //:reviewmap` stops during toolchain analysis:
  `Could not determine Xcode version at all.` No project compilation occurred.

Full Xcode is required to complete Bazel compilation, validate runtime behavior
and report a speed comparison. The configuration is experimental until then.

The initial SwiftPM release run completed these samples (wall time, dependency
downloads excluded):

| Scenario | Seconds | Result |
| --- | ---: | --- |
| Clean build | 259.325 | Success |
| First unchanged rebuild | 250.471 | Success |

The run was stopped during the second unchanged rebuild. Its generated build
history selected `XcodeDefault`, then `CommandLineTools`, then `XcodeDefault`
again, with different SDK stat-cache inputs. This is evidence of unstable build
configuration during this run, not proof of the original slowdown's complete
cause. No source-edit measurements from this initial run completed.

A follow-up probe with `TOOLCHAINS=org.swift.CommandLineTools` completed an
untimed preparation build in 208.603 seconds. Its following unchanged build
again selected the alternate build description and began dependency compilation;
the probe was stopped. Explicit `TOOLCHAINS` selection did not stabilize this
configuration. Neither interrupted build is a completed timing sample.

Swift 6.4's backend change is documented in the [SwiftPM release notes](https://docs.swift.org/latest/documentation/packagemanagerdocs/6.4/).
Do not infer a Bazel speedup from these results. Rerun both systems with the same
full Xcode installation before drawing a comparison.
