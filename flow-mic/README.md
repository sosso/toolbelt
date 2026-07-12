# flow-mic

Keeps a hardware-muted microphone usable for [Wispr Flow](https://wisprflow.ai)
dictation: when a dictation starts, the current mute state is saved and the mic
unmuted; when it stops, the saved state is restored. Mute for a meeting, dictate
mid-meeting with a pedal or hotkey, end up muted again — automatically.

## How it works

A launchd agent (`flow-mic-daemon`) tails Wispr Flow's own log
(`~/Library/Logs/Wispr Flow/accessibility.log`) and reacts to its IPC events:

- `RecordingStarted` → `flow-mic-save` snapshots the mic's hardware mute
  (via [`micctl`](../micctl/)), then unmutes.
- `DictationStop` → `flow-mic-enforce` restores the snapshot — and keeps
  re-applying it for 8 seconds, because Wispr asynchronously unmutes the mic
  2–4 s *after* dictation ends, so a one-shot restore loses that race.

Driving off Wispr's own events (rather than whatever button started dictation)
means there is no toggle state to desync, and keyboard-initiated dictations get
the same treatment as a Stream Deck pedal.

The mic device is currently hardcoded as `Shure MV7+` in `bin/flow-mic-save`,
`bin/flow-mic-enforce`, and `bin/flow-mic-daemon` — adjust for your hardware
(`micctl list` shows device names).

## Install

```sh
../micctl/install.sh   # dependency
./install.sh           # symlinks scripts, installs + starts the launchd agent
```

Daemon log: `~/.local/state/flow-mic-daemon.log`.
Restart: `launchctl kickstart -k gui/$(id -u)/com.toolbelt.flow-mic-daemon`.

## Trigger-side notes (Stream Deck et al.)

Hard-won findings if you're wiring a Stream Deck pedal to Wispr Flow:

- Use a plain **Hotkey action** bound to a Wispr shortcut. Nothing launched via
  Stream Deck's *Open* action can be in the press path: Open force-activates
  the launched app, and a faceless helper app becomes a focus black hole —
  Wispr then can't find your textbox and shows "select a textbox" instead of
  inserting. `LSUIElement`/`LSBackgroundOnly` do not prevent this.
- Wispr's `wispr-flow://start-hands-free` deep link starts recording but skips
  the focused-element snapshot, so insertion fails the same way. (The
  `stop-hands-free` deep link is fine, and usefully idempotent.)
- Wispr shortcut bindings distinguish **left vs right modifiers** — an arrow in
  its settings UI (`^Ctrl→`) means right-side. Stream Deck's Hotkey capture
  records left-side by default; a mismatch fails silently.
- If you must synthesize the shortcut from a script, use
  [`keysend`](../keysend/) — System Events' flags-only keystrokes are invisible
  to Wispr's shortcut listener.
