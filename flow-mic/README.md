# flow-mic

Keeps a hardware-muted microphone usable for [Wispr Flow](https://wisprflow.ai)
dictation: when a dictation starts, the current mute state is saved and the mic
unmuted; when it stops, the saved state is restored. Mute for a meeting, dictate
mid-meeting with a pedal or hotkey, end up muted again — automatically.

## How it works

The trigger is a Hammerspoon hotkey (`../hammerspoon/lua/flow_mic.lua`) bound to
**⌥Space**, which wraps Wispr's own shortcut rather than replacing it:

1. `flow-mic-start` snapshots the mic's hardware mute (via
   [`micctl`](../micctl/)) and unmutes it.
2. [`keysend`](../keysend/) presses Wispr's real shortcut, and Wispr starts
   recording as if you had pressed it yourself.
3. The next ⌥Space opens `wispr-flow://stop-hands-free` to end the dictation,
   then `flow-mic-enforce` restores the snapshot — and keeps re-applying it for
   8 seconds, because Wispr asynchronously unmutes the mic 2–4 s *after*
   dictation ends, so a one-shot restore loses that race.

The two edges are deliberately asymmetric. **Hands-free mode is not a toggle**:
the shortcut starts a dictation but pressing it again will not end one, so the
stop edge has to be the deep link. It cannot be the deep link in both
directions either — `start-hands-free` records without taking Wispr's
focused-element snapshot, so the transcript has nowhere to go. Real keystroke
in, URL out.

Owning the trigger means both edges are known without reading anything Wispr
writes. Wispr can still end a dictation on its own, though — a timeout, a click
on its panel — so while one is live the module polls `flow-mic-active`, which
asks CoreAudio whether anything is actually capturing from the mic. That, not
the toggle bit, is what decides when to restore, which is why the toggle cannot
desync the way pedal-side state used to.

Set your hardware in `bin/flow-mic-lib.sh` (`micctl list` shows device names),
and Wispr's shortcut in `WISPR_CHORD` at the top of the Hammerspoon module.

### Why not read Wispr's log

Versions through mid-2026 logged IPC events (`RecordingStarted`,
`DictationStop`) to `~/Library/Logs/Wispr Flow/accessibility.log`, and flow-mic
1.x ran a launchd agent tailing it. As of **1.6.827** that directory is empty.
The log moved to
`~/Library/Caches/com.electron.wispr-flow.accessibility-mac-app/async.log` and
the accessibility helper still holds it open for writing, but it stays 0 bytes:
the binary's `DevelopmentFileLogWriter` is gated behind a `developmentFileLogging`
flag that now ships off. The event names are all still in the binary, so

```sh
defaults write com.electron.wispr-flow.accessibility-mac-app developmentFileLogging -bool true
```

may bring the log back — but a dev flag that went off once can go off again,
which is why the trigger no longer depends on it.

## Install

```sh
../micctl/install.sh       # dependencies
../keysend/install.sh
./install.sh               # copies the scripts into ~/.local/bin
../hammerspoon/install.sh  # the ⌥Space trigger
```

⌥Space is used because macOS leaves it free. ⌘Space is Spotlight's, and
binding it fails with `RegisterEventHotKey failed: -9878` until "Show Spotlight
search" is turned off under **System Settings → Keyboard → Keyboard
Shortcuts → Spotlight**; the module says so in an alert rather than only in the
Hammerspoon console. The cost of ⌥Space is that you can no longer type a
non-breaking space, since the hotkey swallows the chord first.

Hammerspoon needs Accessibility permission — it already does for hotkeys, and
`keysend` inherits the grant because Hammerspoon is the responsible process.

## Trigger-side notes (Stream Deck et al.)

Hard-won findings if you're wiring a Stream Deck pedal to this:

- Point the pedal's **Hotkey action** at ⌥Space (the wrapper), not at Wispr's
  own shortcut — a press that bypasses the wrapper gets no unmute. The
  `flow-mic-active` poll notices and restores, but the dictation itself is lost.
- Nothing launched via Stream Deck's *Open* action can be in the press path:
  Open force-activates the launched app, and a faceless helper app becomes a
  focus black hole — Wispr then can't find your textbox and shows "select a
  textbox" instead of inserting. `LSUIElement`/`LSBackgroundOnly` do not prevent
  this. Hammerspoon is exempt only because it is already running and a hotkey
  never activates it.
- Wispr's `wispr-flow://start-hands-free` deep link starts recording but skips
  the focused-element snapshot, so insertion fails the same way. (The
  `stop-hands-free` deep link is fine, and usefully idempotent — which is what
  the stop edge above is built on. Open it with `open -g`: without the flag
  Wispr comes to the front, and since insertion happens on stop, that aims the
  transcript at Wispr instead of your textbox.)
- Wispr shortcut bindings distinguish **left vs right modifiers** — an arrow in
  its settings UI (`^Ctrl→`) means right-side. Stream Deck's Hotkey capture
  records left-side by default; a mismatch fails silently. `WISPR_CHORD` names
  each modifier by keycode, so it can say which side it means.
- If you must synthesize the shortcut from a script, use `keysend` — System
  Events' flags-only keystrokes are invisible to Wispr's shortcut listener.
