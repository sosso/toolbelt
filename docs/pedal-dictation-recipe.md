# Recipe: Stream Deck pedal → Wispr Flow dictation with mic mute save/restore

The goal: press a foot pedal to dictate with Wispr Flow, even when the mic is
hardware-muted — unmute for the dictation, then land back in exactly the mute
state you started in. Sounds like a four-step multi-action. It is not.

This doc records the working recipe and, more importantly, every approach that
*didn't* work and why. Most of these failures are invisible-by-design (silent
no-ops, hidden state, focus quirks), so the lessons generalize to any
Stream Deck / global-shortcut / Core Audio automation on macOS.

## The working recipe

Three parts, none of which involve a multi-action:

1. **Stream Deck pedal:** a plain **Hotkey action** sending one of Wispr's
   hands-free shortcuts (⌥Space). A tap toggles dictation on/off. That's the
   pedal's entire job.
2. **Wispr Flow:** stock hands-free mode. No deep links, no scripting.
3. **Mic state:** the [`flow-mic`](../flow-mic/) launchd daemon tails Wispr's
   own log (`~/Library/Logs/Wispr Flow/accessibility.log`) and mirrors
   dictation state onto the mic's hardware mute via [`micctl`](../micctl/):
   `RecordingStarted` → save mute state, unmute; `DictationStop` → restore,
   enforced for 8 s.

The load-bearing design decision: **the pedal knows nothing about the mic, and
the mic logic knows nothing about the pedal.** The daemon reacts to Wispr's own
events, so keyboard-initiated dictations get identical treatment and there is
no toggle state anywhere that can desync.

## What didn't work, in the order we tried it

### 1. AppleScript input volume as the mute control

`osascript -e 'set volume input volume 0'` is the canonical "mute the mic"
recipe — and against a Shure MOTIV Mix Virtual input device it is a **silent
no-op**: the set succeeds, the readback still says 100. The MV7+'s real mute is
`kAudioDevicePropertyMute` on the *physical* device (the touch-panel mute reads
and writes through it), which AppleScript can't reach. Hence `micctl`.

Corollary: the virtual passthrough device exposes mute read-only. Control the
physical device.

### 2. Multi Action Switch for start/stop pairing

Idea: first press = save + start, second press = stop + restore. The Multi
Action Switch keeps **hidden phase state** deciding which half runs next. One
stray press — ever — inverts the halves, silently and persistently (every
2-press cycle preserves the inversion). Ours ran backwards through multiple
test cycles: the "save" executed at dictation *stop*, poisoning the saved state
for the next run. Nothing in the UI shows which half is armed.

### 3. Sequencing save/dictate/restore in one multi-action

Even with correct pairing, Stream Deck fires multi-action steps back-to-back:
"restore" runs a split second after dictation *starts*. And the Open action
only *launches* an app — a script that reads mic state races whatever the
dictation app does at startup. Launch latency (~1.5–2 s for an AppleScript
applet) also means the "save" can read state *after* the dictation app already
changed it.

### 4. Wispr's deep links for start/stop

Wispr Flow has URL routes (`wispr-flow://start-hands-free`, `stop-hands-free` —
found via `strings` on `app.asar`). Two problems:

- `open <url>` activates the app; `open -g` fixes that.
- **`start-hands-free` skips the focused-element snapshot** the hotkey path
  performs. Recording works, but insertion has no target: Wispr ends with
  "select a textbox to dictate" instead of typing. Every time.

`stop-hands-free` is well-behaved and usefully idempotent.

### 5. Any app launch in the press path (the focus black hole)

We wrapped the toggle script in an AppleScript applet for silent execution.
Stream Deck's **Open action force-activates the app it opens** — and an applet
with no windows becomes a **focus black hole**: frontmost goes to the applet
and stays there (11+ s in our logs, until a manual click). Wispr then snapshots
a faceless app instead of your textbox.

Things that do not fix this:
- `LSUIElement` — hides the Dock icon, still activatable.
- `LSBackgroundOnly` — *should* make activation impossible, but LaunchServices
  **caches Info.plist metadata**; edits don't take until `lsregister -f`. And
  even then, Stream Deck's activation still landed the applet frontmost where
  a CLI `open` didn't.
- Making the applet stay-open/resident (fixes launch latency, not focus).

Lesson: nothing launched via Stream Deck's Open action can be in the press
path of anything focus-sensitive. Full stop.

### 6. System Events keystrokes to trigger the shortcut

`tell application "System Events" to key code 49 using option down` returns
rc=0 and does nothing: it sets the modifier *flag* on the key event without
posting a real Option keydown. Wispr's shortcut listener tracks physical
modifier presses (it supports modifier-only Flow keys), so flags-only chords
are invisible to it. Stream Deck's Hotkey action works precisely because it
posts discrete modifier keydown/keyup events — which is what
[`keysend`](../keysend/) replicates via CGEvents.

(Karabiner-Elements can't bridge this either: it only sees physical HID
devices — neither Stream Deck's synthetic events nor the pedal's
vendor-specific HID reports pass through it.)

### 7. One-shot restore after stop

Wispr **asynchronously unmutes the mic 2–4 seconds after dictation ends**, on
its own schedule. A restore fired at stop+0.5 s usually gets overwritten; a
fixed sleep can't win a variable race. The fix is an enforcer: re-apply the
saved state in a short loop (8 s window, 0.3 s cadence), standing down if a new
dictation starts. Only the muted state needs enforcing — Wispr only ever
unmutes — which also guarantees the enforcer can never fight a deliberate
manual unmute.

### 8. Left vs right modifiers in shortcut bindings

Wispr bindings distinguish modifier *sides*. In its settings UI an arrow glyph
(`^Ctrl→`) means **right**-Ctrl; the config stores side-specific keycodes
(61/62 = right-Opt/right-Ctrl). Stream Deck's Hotkey capture records left-side
modifiers by default. The mismatch fails with no feedback anywhere — pedal
pressed, nothing happens. If a binding mysteriously doesn't fire, check sides
first.

## Diagnostic techniques that cracked it

- **A state poller with timestamps.** A 0.15 s loop logging mic mute, "device
  is recording" (`micctl get-running`), the saved-state file's mtime, and the
  frontmost app — only on change. Every breakthrough in this saga came from
  reading that timeline, not from theorizing: the inverted switch halves, the
  late async unmute, and the focus black hole were all discovered as
  timestamped facts.
- **Read the target app's own logs.** Wispr's `accessibility.log` announces
  `RecordingStarted` / `DictationStop` with millisecond timestamps — that
  discovery collapsed the whole architecture into "tail the log."
- **`strings` on the app bundle.** Surfaced the deep-link router, the
  focused-element snapshot machinery, and the chip's trigger event.
- **The app's config beats guessing.** Wispr's `config.json` holds every
  binding as raw keycodes — that's how the right-side-modifier mismatch was
  found.
