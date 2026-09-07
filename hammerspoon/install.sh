#!/bin/bash
# Copies the Hammerspoon modules into ~/.hammerspoon. Only the files this tool
# owns are touched — anything else already there (including modules installed
# from somewhere else) is left alone, and init.lua skips the ones it can't find.
set -euo pipefail
cd "$(dirname "$0")"

[ -d /Applications/Hammerspoon.app ] || { echo "Hammerspoon not installed" >&2; exit 1; }

mkdir -p "$HOME/.hammerspoon"
for f in lua/*.lua; do
  dest="$HOME/.hammerspoon/$(basename "$f")"
  rm -f "$dest"
  install -m 0644 "$f" "$dest"
done

echo "hammerspoon deployed: $(ls lua | tr '\n' ' ')→ ~/.hammerspoon"
echo "  reload it from the menu bar, or with ⌘⌃⌥R"
