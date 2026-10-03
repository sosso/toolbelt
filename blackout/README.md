# blackout

Turns the MacBook's built-in display fully black while external displays keep
working — for using display glasses (XREAL and the like) on a plane without the
seat next to you reading along. Works in both mirror and extended mode.

Click the batarang in the menu bar to toggle it: outlined is off, solid is
blacked out. The menu bar item lives in
[`hammerspoon/lua/blackout.lua`](../hammerspoon/lua/blackout.lua); this
directory is the helper it runs.

```
blackout     # blacks out the built-in until killed (SIGINT/SIGTERM/SIGHUP)
```

## How it works

It zeroes the built-in panel's gamma table rather than covering it with a
window. In mirror mode both displays scan out the same framebuffer, so a black
window would black out the glasses too; gamma is applied per output, after the
framebuffer. On a mini-LED panel an all-black signal also switches the dimming
zones off, so the panel goes dark rather than dim.

macOS restores the gamma the moment the process that set it exits, which makes
that the failsafe: quitting, crashing, or killing the helper brings the screen
straight back. It also exits by itself once no external display is connected,
and refuses to start without one, so unplugging the glasses never leaves you
with no screen. While it runs it reapplies the table every second and on every
display reconfiguration, since macOS rewrites it on wake, Night Shift and True
Tone changes.

## Install

```sh
./install.sh    # compiles to ~/.local/bin/blackout
```
