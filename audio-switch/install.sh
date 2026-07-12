#!/bin/bash
# Copies the audio-switch scripts into ~/.local/bin and rebuilds the silent
# applet wrappers in ~/Applications for Stream Deck's Open action.
set -euo pipefail
cd "$(dirname "$0")"

SAS=/opt/homebrew/bin/SwitchAudioSource
[ -x "$SAS" ] || { echo "SwitchAudioSource missing — brew install switchaudio-osx" >&2; exit 1; }

mkdir -p "$HOME/.local/bin" "$HOME/Applications"
for f in bin/audio-to-*; do
  dest="$HOME/.local/bin/$(basename "$f")"
  rm -f "$dest"
  install -m 0755 "$f" "$dest"
done

for name in AudioToReceiver:audio-to-receiver AudioToSpeakers:audio-to-speakers; do
  app="${name%%:*}"; script="${name##*:}"
  rm -rf "$HOME/Applications/$app.app"
  osacompile -o "$HOME/Applications/$app.app" -e "do shell script \"$HOME/.local/bin/$script\""
done
echo "audio-switch deployed: scripts + ~/Applications/AudioTo{Receiver,Speakers}.app"
