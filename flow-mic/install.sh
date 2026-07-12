#!/bin/bash
# Copies the flow-mic scripts into ~/.local/bin and installs + (re)starts the
# launchd daemon. Deployed files are copies — pulling the repo changes nothing
# until this runs again. Requires micctl (../micctl).
set -euo pipefail
cd "$(dirname "$0")"

command -v "$HOME/.local/bin/micctl" >/dev/null || { echo "micctl missing — run ../micctl/install.sh first" >&2; exit 1; }

mkdir -p "$HOME/.local/bin" "$HOME/.local/state" "$HOME/Library/LaunchAgents"
for f in bin/flow-mic-*; do
  dest="$HOME/.local/bin/$(basename "$f")"
  rm -f "$dest"   # never copy through a stale symlink
  install -m 0755 "$f" "$dest"
done

PLIST="$HOME/Library/LaunchAgents/com.toolbelt.flow-mic-daemon.plist"
sed "s|__HOME__|$HOME|g" launchd/com.toolbelt.flow-mic-daemon.plist.template > "$PLIST"

launchctl bootout "gui/$(id -u)/com.toolbelt.flow-mic-daemon" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "flow-mic deployed; daemon state:"
launchctl print "gui/$(id -u)/com.toolbelt.flow-mic-daemon" | grep "state ="
