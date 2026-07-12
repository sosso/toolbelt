# toolbelt

Small macOS utilities, each in its own directory with an `install.sh`.

| Tool | What it does |
|------|--------------|
| [`micctl`](micctl/) | CLI for Core Audio input devices: get/set hardware mute and volume, check whether a device is recording. Reaches the device-level controls AppleScript can't. |
| [`keysend`](keysend/) | Synthesizes a keyboard chord with *real* modifier keydown/keyup events (the way hardware does it), for apps whose shortcut listeners ignore flags-only synthetic events. |
| [`flow-mic`](flow-mic/) | launchd daemon that saves/restores a mic's hardware mute state around Wispr Flow dictations: unmutes when recording starts, restores your previous state when it stops. |

## Install

```sh
./micctl/install.sh     # required by flow-mic
./keysend/install.sh
./flow-mic/install.sh
```

Binaries and script symlinks land in `~/.local/bin`. Swift tools compile with the
stock Command Line Tools (`swiftc`), no other dependencies.
