#!/bin/bash
# Copies the flow-mic scripts into ~/.local/bin. Deployed files are copies —
# pulling the repo changes nothing until this runs again. Requires micctl
# (../micctl) and keysend (../keysend); the trigger itself lives in
# ../hammerspoon, which has its own install.sh.
set -euo pipefail
cd "$(dirname "$0")"

for dep in micctl keysend; do
  [ -x "$HOME/.local/bin/$dep" ] || { echo "$dep missing — run ../$dep/install.sh first" >&2; exit 1; }
done

mkdir -p "$HOME/.local/bin" "$HOME/.local/state"
for f in bin/flow-mic-*; do
  dest="$HOME/.local/bin/$(basename "$f")"
  rm -f "$dest"   # never copy through a stale symlink
  install -m 0755 "$f" "$dest"
done

# Scripts this tool deployed in an earlier version and no longer ships.
# Without this they linger in ~/.local/bin, still runnable, still carrying the
# device name they were configured with.
for dest in "$HOME"/.local/bin/flow-mic-*; do
  [ -e "bin/$(basename "$dest")" ] || { rm -f "$dest"; echo "pruned stale $(basename "$dest")"; }
done

# The 1.x design ran a launchd agent tailing Wispr's log; the hotkey wrapper
# replaced it. Leaving it loaded would fight the Hammerspoon module over the
# same mute control.
AGENT="com.toolbelt.flow-mic-daemon"
PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"
if [ -e "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed the obsolete $AGENT launch agent"
fi

echo "flow-mic deployed to ~/.local/bin"
