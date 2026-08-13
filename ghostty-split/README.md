# ghostty-split

Splits the focused Ghostty pane 50/50 downward and runs something in the bottom
half, in the same working directory.

```sh
ghostty-split                   # a shell
ghostty-split claude            # a Claude Code session
ghostty-split claude --continue # resume the last session in that directory
ghostty-split rsv2 status       # any command
ghostty-split-claude            # shorthand for `ghostty-split claude`
```

Arguments are joined into one command line and run by an interactive login zsh, the
way `ssh host cmd…` behaves: quoting is interpreted by *that* shell, not by the one
you type into. Quote for the inner shell — `ghostty-split "touch \"it's ok.txt\""`.

Requires Ghostty 1.3+, which ships an AppleScript dictionary
(`/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef`).

## Stream Deck

`install.sh` compiles a silent applet per entry in its `APPLETS` list, the same
trick `audio-switch` uses for Stream Deck's **System → Open** action:

| Applet | Runs |
|--------|------|
| `~/Applications/GhosttySplitClaude.app` | `claude` |
| `~/Applications/GhosttySplitRsv2.app` | `rsv2` |
| `~/Applications/GhosttySplitShell.app` | a plain shell |

Add a button: Stream Deck → **System → Open** → pick the applet. For a new one,
append `"AppName:command"` to `APPLETS` and re-run `install.sh`.

The split lands in Ghostty's frontmost *window*, which is not necessarily the app
you are looking at — pressing a Stream Deck key doesn't change which window that
is, so the pane appears wherever Ghostty last had focus.

## Hotkey

Ghostty has no keybind action that runs a script — `ghostty +list-actions` has
`new_split`, `text`, and friends, but nothing that shells out. So the hotkey comes
from macOS:

1. Shortcuts.app → new shortcut → **Run Shell Script** → `$HOME/.local/bin/ghostty-split claude`
2. Shortcut details (ⓘ) → **Add Keyboard Shortcut** → e.g. `cmd+shift+return`
3. First run prompts for Apple Events permission for Shortcuts → Ghostty.

## Two things that make this less trivial than it looks

**The command needs a login shell.** Ghostty launches a surface's `command` under
`login -flp … /bin/bash --noprofile --norc`, so `~/.local/bin` and the
rbenv/nvm/pyenv shims are missing from PATH: bare `claude` dies instantly with
"Ghostty failed to launch the requested command". Hence the `zsh -ilc` wrapper,
which also gives the session the same PATH a hand-started one would have.

**That bash re-parses the command**, so a command interpolated into the `zsh -ilc '…'`
string is quote-mangled by two shells before it runs — `ghostty-split "touch \"it's ok\""`
died on `zsh:1: unmatched '` no matter how carefully the quotes were escaped for one
level. The command travels in the `GHOSTTY_SPLIT_CMD` environment variable instead,
where no shell parses it, and zsh's `eval` reads it exactly once.

**Working directory comes from shell integration**, reported via OSC 7 at each
prompt. It is empty until the pane's shell draws its first prompt (the script polls
up to 3s, then falls back to `~`), and it reflects the *last prompt*, not live
`$PWD` — `cd` then hitting the hotkey before the next prompt renders gives the
previous directory. A pane running Claude reports the directory it was started in,
which is the one you want.

Note that `initial working directory` is write-only: it is a surface-configuration
key, not a readable property of a terminal, so it can't serve as a fallback.

To see what a pane reports:

```sh
osascript -e 'tell application "Ghostty" to return working directory of focused terminal of selected tab of front window'
```

## What Ghostty can't do

There is no way to *move* an existing tab into a split — tabs and splits are
separate structures with no reparenting action (`move_tab` only reorders tabs).
Folding a tab into a pane means recreating it: split, start a shell in the old
tab's directory, close the tab. Whatever was running in it dies.
