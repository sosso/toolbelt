# audio-switch

Switches macOS audio output between a bluetooth receiver and the built-in
speakers — one script per destination, plus silent `.app` wrappers so a
Stream Deck **Open** action can fire them without a Terminal window (used in
dock/undock multi-actions).

```
audio-to-receiver   # SwitchAudioSource -s "Music Receiver"
audio-to-speakers   # SwitchAudioSource -s "MacBook Pro Speakers"
```

Requires [`switchaudio-osx`](https://github.com/deweller/switchaudio-osx)
(`brew install switchaudio-osx`). Device names are hardcoded in `bin/` —
`SwitchAudioSource -a` lists yours.

`install.sh` copies the scripts to `~/.local/bin` and compiles the applets to
`~/Applications/AudioToReceiver.app` / `AudioToSpeakers.app`.

Note on the Open action: launching an applet briefly activates it, which is
harmless here (audio switching isn't focus-sensitive, and these applets quit
immediately). Don't reuse this wrapper pattern for anything that needs the
user's focus preserved — see
[the pedal recipe, dead end #5](../docs/pedal-dictation-recipe.md).
