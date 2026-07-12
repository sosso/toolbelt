# keysend

Synthesizes a keyboard chord as a sequence of **real key events** — discrete
modifier keydowns, then the key, then releases in reverse order — posted to the
HID event tap. This is what hardware (and Stream Deck's Hotkey action) looks
like to event listeners.

Why not `osascript -e 'tell app "System Events" to key code 49 using option down'`?
System Events sets the modifier *flag* on the key event without ever posting a
modifier keydown. Apps whose global-shortcut listeners track physical modifier
state (Wispr Flow, anything supporting modifier-only or Fn shortcuts) never see
the chord. `keysend` does.

```
keysend <keycode> [modifier-keycode ...]

keysend 49 58        # Option+Space  (space=49, left-option=58)
keysend 111 61 62    # rOpt+rCtrl+F12
```

Keycodes are macOS virtual keycodes (`kVK_*`). Modifier keycodes map to their
event flags automatically: cmd 54/55, shift 56/60, option 58/61, control 59/62,
fn 63.

Requires Accessibility permission for whatever process runs it (a terminal,
a launchd agent, Stream Deck — TCC attributes to the responsible app).
