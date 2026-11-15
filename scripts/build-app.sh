#!/bin/sh
# Builds the Review Map app (the rebuild; see docs/rebuild-phase1-proposal.md): the Swift helper, the
# `reviewmap` command, the UI, and the macOS bundle that holds all three.
#
#   scripts/build-app.sh             build target/release/bundle/macos/Review Map.app
#   scripts/build-app.sh --install   also copy it to ~/Applications and link ~/.local/bin/reviewmap to
#                                    the command inside it (PREFIX=/some/dir changes ~/.local)
#   scripts/build-app.sh --dev       prepare the helper and the command, then run the app from source
#                                    (`tauri dev`, with the UI served by Vite and reloaded on change)
#
# Needs: a Rust toolchain, Node 20 or later, and full Xcode (for Swift and libIndexStore).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-build}
triple=$(rustc -vV | sed -n 's/^host: //p')
binaries="$root/app/src-tauri/binaries"

echo "Building the Swift helper…"
(cd "$root/helper" && swift build -c release --product reviewmap-swift-helper)

echo "Building the reviewmap command…"
(cd "$root" && cargo build --release -p reviewmap-cli)

# Tauri bundles these next to the app's executable, without the target suffix.
mkdir -p "$binaries"
cp "$root/helper/.build/release/reviewmap-swift-helper" "$binaries/reviewmap-swift-helper-$triple"
cp "$root/target/release/reviewmap" "$binaries/reviewmap-$triple"

cd "$root/app"
if [ ! -d node_modules ] || [ package-lock.json -nt node_modules ]; then
  echo "Installing the UI's dependencies…"
  npm ci --no-audit --no-fund
fi

if [ "$mode" = "--dev" ]; then
  exec npx tauri dev
fi

echo "Building the app…"
npx tauri build
app="$root/target/release/bundle/macos/Review Map.app"
echo "Built $app"

if [ "$mode" = "--install" ]; then
  prefix=${PREFIX:-$HOME/.local}
  mkdir -p "$HOME/Applications" "$prefix/bin"
  rm -rf "$HOME/Applications/Review Map.app"
  cp -R "$app" "$HOME/Applications/Review Map.app"
  ln -sf "$HOME/Applications/Review Map.app/Contents/MacOS/reviewmap" "$prefix/bin/reviewmap"
  echo "Installed ~/Applications/Review Map.app and $prefix/bin/reviewmap"
  case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "Add $prefix/bin to your PATH to run reviewmap from anywhere." ;;
  esac
else
  echo "Run it with: $root/target/release/reviewmap [repo] [--base main] [--head <branch>]"
fi
