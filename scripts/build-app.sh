#!/bin/sh
# Builds the Review Map app (the rebuild; see docs/rebuild-phase1-proposal.md) with Bazel: the Swift helper,
# the `reviewmap` command, the UI, and the macOS bundle that holds all three (//app:bundle, optimized).
#
#   scripts/build-app.sh             build Review Map.app and print where it is
#   scripts/build-app.sh --install   also copy it to ~/Applications and link ~/.local/bin/reviewmap to
#                                    the command inside it (PREFIX=/some/dir changes ~/.local)
#
# For work on the UI alone, `REVIEWMAP_REPORT=<report.json> bazel run //app:dev` serves it in a browser
# with reloads (see app/dev.mjs).
#
# Needs: Bazel (or Bazelisk) and full Xcode (for Swift and libIndexStore). Bazel fetches Rust, Node.js and
# every package itself.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-build}
case "$mode" in
  build | --install) ;;
  *)
    echo "usage: scripts/build-app.sh [--install]" >&2
    exit 2
    ;;
esac

cd "$root"
bazel build --config=release //app:bundle
app="$root/$(bazel cquery --config=release --output=files //app:bundle 2>/dev/null)"
echo "Built $app"

if [ "$mode" = "--install" ]; then
  prefix=${PREFIX:-$HOME/.local}
  mkdir -p "$HOME/Applications" "$prefix/bin"
  rm -rf "$HOME/Applications/Review Map.app"
  cp -R "$app" "$HOME/Applications/Review Map.app"
  # Bazel's outputs are read-only; the installed copy is the user's.
  chmod -R u+w "$HOME/Applications/Review Map.app"
  ln -sf "$HOME/Applications/Review Map.app/Contents/MacOS/reviewmap" "$prefix/bin/reviewmap"
  echo "Installed ~/Applications/Review Map.app and $prefix/bin/reviewmap"
  case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "Add $prefix/bin to your PATH to run reviewmap from anywhere." ;;
  esac
else
  echo "Run it with: \"$app/Contents/MacOS/reviewmap\" [repo] [--base main] [--head <branch>]"
fi
