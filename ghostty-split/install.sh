#!/bin/bash
# Copies the ghostty-split scripts into ~/.local/bin and rebuilds the silent applet
# wrappers in ~/Applications for Stream Deck's Open action. Add your own panes by
# appending to APPLETS: "AppName:command to run".
set -euo pipefail
cd "$(dirname "$0")"

[ -d /Applications/Ghostty.app ] || { echo "Ghostty not installed" >&2; exit 1; }
[ -f /Applications/Ghostty.app/Contents/Resources/Ghostty.sdef ] || {
  echo "Ghostty has no AppleScript dictionary — needs 1.3 or newer" >&2; exit 1; }

APPLETS=(
  "GhosttySplitClaude:claude"
  "GhosttySplitTop:htop"
  "GhosttySplitShell:"
)

mkdir -p "$HOME/.local/bin" "$HOME/Applications"
for f in bin/*; do
  dest="$HOME/.local/bin/$(basename "$f")"
  rm -f "$dest"
  install -m 0755 "$f" "$dest"
done

for entry in "${APPLETS[@]}"; do
  app="${entry%%:*}"; cmd="${entry#*:}"
  rm -rf "$HOME/Applications/$app.app"
  osacompile -o "$HOME/Applications/$app.app" \
    -e "do shell script \"$HOME/.local/bin/ghostty-split $cmd\""
done

echo "ghostty-split deployed: scripts + ~/Applications/GhosttySplit{Claude,Top,Shell}.app"
