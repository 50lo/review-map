#!/bin/sh
# Builds reviewmap and installs it for the current user:
#   <prefix>/bin/reviewmap               the analyzer
#   <prefix>/share/reviewmap/viewer      the viewer, with its npm dependencies
#
#   scripts/install.sh              install to ~/.local (or $PREFIX)
#   scripts/install.sh --uninstall  remove both
#
# Run it again after pulling to update. The installed binary doesn't need this checkout.

set -eu

prefix=${PREFIX:-$HOME/.local}
bin="$prefix/bin"
share="$prefix/share/reviewmap"
root=$(cd "$(dirname "$0")/.." && pwd)

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$bin/reviewmap"
  rm -rf "$share"
  echo "Removed $bin/reviewmap and $share."
  exit 0
fi
if [ $# -gt 0 ]; then
  echo "usage: scripts/install.sh [--uninstall]" >&2
  exit 2
fi

for tool in swift node npm git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is not installed. reviewmap needs Swift 6.2 (Xcode 26 on macOS), Node 20 or later, and git." >&2
    exit 1
  fi
done

echo "Building reviewmap (release)…"
cd "$root"
swift build -c release --product reviewmap
built="$(swift build -c release --show-bin-path)/reviewmap"

mkdir -p "$bin" "$share/viewer"
install -m 755 "$built" "$bin/reviewmap"

# npm ci only when the dependencies changed since the last install.
deps_changed=1
if [ -d "$share/viewer/node_modules" ] && cmp -s viewer/package-lock.json "$share/viewer/package-lock.json"; then
  deps_changed=0
fi
echo "Copying the viewer to $share/viewer…"
find "$share/viewer" -mindepth 1 -maxdepth 1 ! -name node_modules -exec rm -rf {} +
(cd viewer && tar -cf - --exclude ./node_modules --exclude ./dist .) | (cd "$share/viewer" && tar -xf -)
if [ $deps_changed -eq 1 ]; then
  echo "Installing viewer dependencies…"
  (cd "$share/viewer" && npm ci --no-audit --no-fund --loglevel=error)
fi

echo "Installed $("$bin/reviewmap" --version) to $bin/reviewmap."
case ":$PATH:" in
  *":$bin:"*) ;;
  *)
    echo
    echo "$bin is not on your PATH. Add this line to your shell profile (~/.zshrc on macOS):"
    echo "  export PATH=\"$bin:\$PATH\""
    ;;
esac
