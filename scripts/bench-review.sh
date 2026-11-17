#!/bin/bash
# Benchmarks one review with the CLI's --report mode, in a Review Map home of its own.
#
#   scripts/bench-review.sh --home <home> --out <dir> [options] <repo> <base> <head> [reviewmap args...]
#   scripts/bench-review.sh --clean <home>
#
# Runs `reviewmap <repo> --base <base> --head <head> --no-llm --report <dir>/report.json [reviewmap args...]`
# from inside <repo> with REVIEWMAP_HOME=<home>, and writes to <dir>:
#   log.txt       every stderr line, prefixed with the seconds since the start (the core's `[timing]` lines too)
#   summary.txt   total time, load average at start and end, peak RSS, disk use of <home>/cache
#   report.json   the report
#   profiles/     with --profiles: Bazel's command.profile.gz after every Bazel build and query
# scripts/bench-phases.py turns log.txt files into the phase table of docs/rebuild-step5-speed.md.
#
# Options:
#   --bin <dir>        where reviewmap and reviewmap-swift-helper are: a directory holding both, or a Bazel
#                      output tree (bazel-bin). Default: this checkout's bazel-bin. Copy them out of bazel-bin
#                      to keep them, since the next build replaces them.
#   --compare <json>   after the run, compare the report with a baseline report (`jq -S` of both) and fail when
#                      they differ. Both runs must use the same clone path and the same home path: the report
#                      names the repository's root, and some warnings name log files under the home.
#   --profiles         keep a copy of Bazel's JSON trace profile after every Bazel build and query (REVIEWMAP_PROFILE_DIR)
#   --keep-bazel       leave the home's Bazel servers running at the end (REVIEWMAP_KEEP_BAZEL=1), as the app
#                      does between reviews of one session; the next run is then a "session" run
#   --label <text>     the run's name in the phase table (default: the basename of <dir>)
#   --state <text>     the cache state, for the phase table: cold, reopen, session, ...
#   --clean <home>     stop the Bazel servers of <home>, make it writable, and delete it
#
# Never point --home at the app's own cache (~/Library/Caches/reviewmap): use a scratch directory.
set -u

die() { echo "bench-review: $*" >&2; exit 2; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# A home that is safe to delete: not empty, not /, not the user's home or the app's own cache.
check_home() {
  local h=$1
  [ -n "$h" ] || die "no home given"
  case "$h" in
    /|"$HOME"|"$HOME"/|"$HOME/Library"*|"$HOME/Library/Caches/reviewmap"*) die "refusing to use $h as a scratch home" ;;
  esac
}

clean() {
  local home=$1
  check_home "$home"
  [ -e "$home" ] || { echo "clean: $home does not exist"; return 0; }
  home=$(cd "$home" && pwd -P)
  # Each output base remembers its workspace in DO_NOT_BUILD_HERE; `bazel shutdown` runs there, so Bazelisk
  # picks the version that started the server.
  local ob ws
  for ob in "$home"/cache/bazel/*/*/out/*; do
    [ -d "$ob/server" ] || continue
    ws=$(cat "$ob/DO_NOT_BUILD_HERE" 2>/dev/null)
    [ -d "$ws" ] || ws=/tmp
    (cd "$ws" && bazel --output_base="$ob" shutdown >/dev/null 2>&1) &
  done
  wait
  # Whatever did not stop (a workspace that is gone, a client that could not start).
  pkill -f -- "--output_base=$home/" 2>/dev/null && sleep 1
  chmod -R u+w "$home" 2>/dev/null
  rm -rf "$home"
  if [ -e "$home" ]; then die "could not delete $home"; fi
  echo "clean: $home deleted"
}

home= out= bin= compare= profiles= keep_bazel= label= state=
while [ $# -gt 0 ]; do
  case "$1" in
    --home) home=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --bin) bin=$2; shift 2 ;;
    --compare) compare=$2; shift 2 ;;
    --profiles) profiles=1; shift ;;
    --keep-bazel) keep_bazel=1; shift ;;
    --label) label=$2; shift 2 ;;
    --state) state=$2; shift 2 ;;
    --clean) clean "${2:-}"; exit $? ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) break ;;
  esac
done
[ $# -ge 3 ] || die "usage: bench-review.sh --home <home> --out <dir> [options] <repo> <base> <head> [reviewmap args...]"
[ -n "$out" ] || die "--out is required"
check_home "$home"
repo=$1 base=$2 head=$3
shift 3
command -v jq >/dev/null || die "jq is needed"
[ -z "$compare" ] || [ -f "$compare" ] || die "no baseline report at $compare"

here=$(cd "$(dirname "$0")/.." && pwd -P)
bin=${bin:-$here/bazel-bin}
if [ -x "$bin/reviewmap" ]; then
  reviewmap=$bin/reviewmap helper=$bin/reviewmap-swift-helper
else
  reviewmap=$bin/crates/cli/reviewmap helper=$bin/helper/reviewmap-swift-helper
fi
[ -x "$reviewmap" ] || die "no reviewmap in $bin (build it with: bazel build --config=release //crates/cli:reviewmap //helper:reviewmap-swift-helper)"
reviewmap=$(cd "$(dirname "$reviewmap")" && pwd -P)/$(basename "$reviewmap")

mkdir -p "$out" "$home" || die "could not create $out or $home"
out=$(cd "$out" && pwd -P)
home=$(cd "$home" && pwd -P)
repo=$(cd "$repo" && pwd -P) || die "no repository at $repo"
label=${label:-$(basename "$out")}
rm -rf "$out/profiles" "$out/report.json" "$out/compare.diff"

export REVIEWMAP_HOME=$home
[ -x "$helper" ] && export REVIEWMAP_SWIFT_HELPER=$(cd "$(dirname "$helper")" && pwd -P)/$(basename "$helper")
if [ -n "$profiles" ]; then export REVIEWMAP_PROFILE_DIR=$out/profiles; else unset REVIEWMAP_PROFILE_DIR; fi
if [ -n "$keep_bazel" ]; then export REVIEWMAP_KEEP_BAZEL=1; else unset REVIEWMAP_KEEP_BAZEL; fi

load_start=$(sysctl -n vm.loadavg)
start=$(now)
# From inside the repository: the CLI passes its directory on, and the review's primary Bazel workspace is the
# one around it.
(
  cd "$repo" || exit 2
  "$reviewmap" "$repo" --base "$base" --head "$head" --no-llm --report "$out/report.json" "$@" 2>&1
  echo "$?" > "$out/.exit"
  now > "$out/.end"
) | perl -MTime::HiRes=time -ne 'BEGIN { $| = 1; $s = '"$start"' } printf "%7.2f %s", time - $s, $_' > "$out/log.txt" &
pipe=$!

# Peak RSS: the processes whose command line names the home (Bazel servers and the tools they start), and
# reviewmap with the indexers it starts. Bazel's Swift and Java workers don't name the output base, so the
# first number is a lower bound.
rss() { ps -axo rss=,command= | grep -F -- "$1" | grep -v -e grep -e bench-review | awk '{ s += $1 } END { print s + 0 }'; }
peak_home=0 peak_tools=0
while kill -0 "$pipe" 2>/dev/null; do
  h=$(rss "$home")
  t=$(ps -axo rss=,command= | grep -E -- "$reviewmap|reviewmap-swift-helper|scip-typescript|scip-java|kotlin_analysis" | grep -v -e grep -e bench-review | awk '{ s += $1 } END { print s + 0 }')
  [ "$h" -gt "$peak_home" ] && peak_home=$h
  [ "$t" -gt "$peak_tools" ] && peak_tools=$t
  sleep 0.5
done
wait "$pipe"
end=$(cat "$out/.end" 2>/dev/null || now)
status=$(cat "$out/.exit" 2>/dev/null || echo 1)
rm -f "$out/.exit" "$out/.end"

{
  echo "run: $label"
  echo "state: ${state:-}"
  echo "command: $reviewmap $repo --base $base --head $head --no-llm --report $out/report.json $*"
  echo "home: $home"
  echo "exit: $status"
  printf "total: %.2f s\n" "$(echo "$end - $start" | bc)"
  echo "load at start: $load_start"
  echo "load at end: $(sysctl -n vm.loadavg)"
  echo "peak RSS, processes naming the home (Bazel servers): $((peak_home / 1024)) MB"
  echo "peak RSS, reviewmap and indexers: $((peak_tools / 1024)) MB"
  echo "disk:"
  du -sk "$home"/cache/* "$home"/cache/bazel/* "$home"/cache/bazel/*/* 2>/dev/null | awk '{ printf "  %8.0f MB %s\n", $1 / 1024, $2 }'
} > "$out/summary.txt"
cat "$out/summary.txt"

[ "$status" = 0 ] || { echo "bench-review: reviewmap failed (exit $status); see $out/log.txt" >&2; exit 1; }
if [ -n "$compare" ]; then
  if diff <(jq -S . "$compare") <(jq -S . "$out/report.json") > "$out/compare.diff"; then
    rm -f "$out/compare.diff"
    echo "compare: the report is the same as $compare"
  else
    echo "compare: the report differs from $compare ($(wc -l < "$out/compare.diff" | tr -d ' ') diff lines, in $out/compare.diff):" >&2
    head -40 "$out/compare.diff" >&2
    exit 1
  fi
fi
