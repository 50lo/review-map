# Bazel build experiment

This branch adds a native Bazel build of the Swift analyzer alongside SwiftPM.
It uses `rules_swift` and `rules_swift_package_manager`: dependencies are compiled
by Bazel, rather than wrapping `swift build` in a Bazel action. `Package.swift`
and `Package.resolved` remain the source of dependency versions.

The Xcode 27.2 comparison below is complete. Bazel improves unchanged and CLI-edit
builds, but does not provide a broad speedup for this project: release clean/core
builds are similar, and SwiftPM is faster for debug clean/core builds.

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

## Xcode 27.2 comparison — 5 November 2026

Measured commit: `4b98a561c77d68382659a308c0ffc53c9fff6d07`, with a clean working
tree at the start of both benchmark runs. Both systems used:

- Mac mini (`Macmini9,1`), 8 logical CPUs, macOS 27.0.1, arm64.
- Xcode 27.2, build `27B52`, selected through
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Apple Swift 6.4.2 (`swiftlang-6.4.2.1.9`, `clang-2100.4.1.1`).
- The existing SwiftPM dependency pins; Bazel 9.3.1, `rules_swift` 3.6.1 and
  `rules_swift_package_manager` 1.25.0.

All values below are wall time in seconds. Clean builds have one sample each;
warm rows are medians of three samples. The scope is the Swift analyzer executable.

| Scenario | SwiftPM release | Bazel release | SwiftPM debug | Bazel debug |
| --- | ---: | ---: | ---: | ---: |
| Clean build | 225.553 | 220.927 | 40.441 | 74.671 |
| Unchanged rebuild | 2.074 | 0.129 | 2.070 | 0.120 |
| CLI code edit | 5.625 | 1.673 | 3.085 | 1.336 |
| Core-library code edit | 33.754 | 32.291 | 3.508 | 6.250 |

Bazel's unchanged builds are about 16–17 times faster, and its CLI edits are
about 3.4 times faster in release and 2.3 times faster in debug. The absolute
savings are roughly two seconds for an unchanged build and two to four seconds
for a CLI edit.

Release clean compilation differs by only about 2%, from one trial per system;
that is too small a difference to treat as a meaningful clean-build win.
Release core edits differ by about 4%. In debug, Bazel takes about 1.8 times as
long for both clean builds and core edits. These results favor keeping SwiftPM
as the default for work on `ReviewMapCore`, while retaining this branch as the
Bazel experiment.

The earlier four-minute unchanged SwiftPM rebuild does not reproduce with the
new Xcode toolchain: unchanged SwiftPM builds consistently take about two seconds.
The old Command Line Tools run also used an older compiler and SDK, so it is
diagnostic history rather than the baseline for the Bazel comparison.

### Method and individual samples

The script ran SwiftPM first, then Bazel, serially for each configuration, with
each build system's default local parallelism. Downloads and Bazel's preparation
build were excluded. Clean means compiled outputs were removed with
`swift package clean` or `bazel clean`; dependency repositories and OS caches
were warm, and the Bazel server was already running. Bazel disk-cache and
remote-cache reads were disabled. These are local build-system defaults, rather
than identical compiler invocations or first-install measurements.

The edit scenarios change one executable-code string in
`Sources/reviewmap/main.swift` or `Sources/ReviewMapCore/ChangeReportIO.swift`.
They include compilation and linking, and the original source is restored and
rebuilt after each scenario. They do not measure API changes, large refactors,
branch switching, CI, or shared remote caches.

| Configuration / scenario | SwiftPM samples (s) | Bazel samples (s) |
| --- | --- | --- |
| Release / unchanged | 1.970, 2.074, 2.088 | 0.148, 0.129, 0.110 |
| Release / CLI edit | 5.556, 5.625, 5.776 | 1.711, 1.673, 1.647 |
| Release / core edit | 33.687, 33.754, 34.067 | 32.134, 32.291, 32.540 |
| Debug / unchanged | 2.070, 2.076, 2.028 | 0.144, 0.120, 0.100 |
| Debug / CLI edit | 2.965, 3.106, 3.085 | 1.336, 1.362, 1.332 |
| Debug / core edit | 3.504, 3.508, 3.730 | 6.264, 6.168, 6.250 |

Reproduce these runs from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/benchmark-builds.py --output .build/experiment/xcode27-release.json
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/benchmark-builds.py --configuration debug --output .build/experiment/xcode27-debug.json
```

The JSON files record all 40 successful measured builds, exact commands,
toolchain metadata and per-build log paths. They and their corresponding
`*-logs/` directories are retained locally under the ignored `.build/experiment/`.

### Build fixes and validation

The native Bazel build required explicit sandbox inputs for tree-sitter's shared
`common/scanner.h`, IndexStoreDB's LLVM Unix/Windows `.inc` fragments and its
`indexstore_functions.def`. These declarations are in `MODULE.bazel`; application
sources and dependency versions were unchanged.

Both release executables passed version/help checks and produced identical parsed
JSON models for the Swift `basic` fixture (38 entities) and the `typescript`
fixture (28 entities). Both models also matched the repository snapshots after
normalizing temporary repository paths and commit SHAs. Both debug executables
passed version checks. All benchmark source edits were restored. This validation
does not add a native Bazel test target or replace the SwiftPM test suite.

## Initial Command Line Tools check — before Xcode installation

- Base commit: `681efc8`.
- Mac mini (`Macmini9,1`), 8 logical CPUs; macOS 27.0.1, arm64; Apple Swift 6.4
  from `/Library/Developer/CommandLineTools`. `swift build --help` reports
  `swiftbuild` as its default backend; the baseline uses that default.
- Bazel 9.3.1; `rules_swift` 3.6.1; `rules_swift_package_manager` 1.25.0.
- `bazel mod tidy` and `bazel query 'deps(//:reviewmap)'` succeed.
- `bazel build --config=release //:reviewmap` stops during toolchain analysis:
  `Could not determine Xcode version at all.` No project compilation occurred.

At this point, full Xcode was still required to complete Bazel compilation and
report a speed comparison. The later Xcode results above supersede that blocker.

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
These Command Line Tools results alone cannot establish a Bazel speedup; the
comparison above reruns both systems with the same full Xcode installation.
