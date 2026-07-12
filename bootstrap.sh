#!/bin/bash
# The apply ritual. Deployed files are copies — `git pull` changes nothing
# until this is run. `./bootstrap.sh diff` previews what apply would change.
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "diff" ]; then
  rc=0
  for f in */bin/*; do
    dest="$HOME/.local/bin/$(basename "$f")"
    diff -uN "$dest" "$f" || rc=1
  done
  PLIST="$HOME/Library/LaunchAgents/com.toolbelt.flow-mic-daemon.plist"
  sed "s|__HOME__|$HOME|g" flow-mic/launchd/com.toolbelt.flow-mic-daemon.plist.template | diff -u "$PLIST" - || rc=1
  echo "(Swift tools are rebuilt from source on every apply; not diffed.)"
  [ $rc -eq 0 ] && echo "no changes: deployed files match the repo."
  exit 0
fi

xcode-select -p >/dev/null 2>&1 || { echo "Xcode Command Line Tools required (xcode-select --install)" >&2; exit 1; }

./micctl/install.sh
./keysend/install.sh
./flow-mic/install.sh
if [ -x /opt/homebrew/bin/SwitchAudioSource ]; then
  ./audio-switch/install.sh
else
  echo "audio-switch skipped (brew install switchaudio-osx to enable)"
fi

echo "toolbelt applied."
