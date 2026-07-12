# toolbelt

Small macOS utilities, each in its own directory with an `install.sh`.

| Tool | What it does |
|------|--------------|
| [`micctl`](micctl/) | CLI for Core Audio input devices: get/set hardware mute and volume, check whether a device is recording. Reaches the device-level controls AppleScript can't. |
| [`keysend`](keysend/) | Synthesizes a keyboard chord with *real* modifier keydown/keyup events (the way hardware does it), for apps whose shortcut listeners ignore flags-only synthetic events. |
| [`flow-mic`](flow-mic/) | launchd daemon that saves/restores a mic's hardware mute state around Wispr Flow dictations: unmutes when recording starts, restores your previous state when it stops. |
| [`audio-switch`](audio-switch/) | Output-device switching scripts (receiver ↔ built-in speakers) with silent applet wrappers for Stream Deck dock/undock multi-actions. |

## Install

```sh
git clone <this repo> ~/workspace/toolbelt
~/workspace/toolbelt/bootstrap.sh
```

Binaries and scripts land in `~/.local/bin`. Swift tools compile with the stock
Command Line Tools (`swiftc`), no other dependencies. Tools can also be
installed individually via each directory's `install.sh`.

## Trust model

Deployed files are **copies**, not symlinks — `git pull` changes nothing on the
live system, including the login-persistent flow-mic daemon. Changes reach the
machine only through the explicit apply ritual:

```sh
./bootstrap.sh diff   # preview what apply would change
./bootstrap.sh        # rebuild, redeploy, restart daemons
```

Review the diff after every pull, then apply deliberately. Never automate the
apply.
