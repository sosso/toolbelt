# hammerspoon

A menu bar item for your open pull requests, bucketed by whether they can
actually merge, plus the small styling library it is built on.

```
PR 19⚠ 4✗ 3✓
```

Conflicts, CI failing, CI running, ready to merge — counted in the menu bar,
listed in the menu. Opening the menu gives you each PR grouped by repository,
with the number, title and age in aligned columns, and an "open all" action per
repository.

Requires the [`gh`](https://cli.github.com) CLI, logged in. One
`gh api graphql` search covers every repository you have an open PR in, so the
poll is a single request no matter how many there are.

## Files

| File | What it is |
|------|------------|
| `lua/init.lua` | Loads the modules, auto-reloads on save, tears watchers down on reload |
| `lua/util.lua` | Dracula/Alucard palette, monospaced row layout, subprocess and terminal helpers |
| `lua/github_prs.lua` | The pull request menu bar item |

`init.lua` treats every module as optional, so you can drop your own alongside
these and list it there. A module that is *present but broken* still reports
its error — only a genuinely missing one is skipped.

## Theme

Rows follow the system appearance: [Dracula](https://draculatheme.com) in dark
mode, its official light counterpart Alucard in light. Both palettes live in
`util.lua`; swap the hex values there for a different theme.

Two constraints worth knowing before editing the styling:

- **Bold only works in a monospaced font.** The system UI font has no
  PostScript name for its bold face, so asking for one silently falls back to
  the regular font at the default size — `util.text` honours `bold` only
  alongside `mono`.
- **Menu chrome is drawn by macOS** and is translucent. A run's
  `backgroundColor` is the only paintable surface, and per-row slabs look
  ragged. For an opaque menu, turn on System Settings → Accessibility →
  Display → Reduce transparency.

## Install

```sh
./install.sh          # or ../bootstrap.sh for the whole toolbelt
```

Files are copied, not symlinked. Reload Hammerspoon afterwards (⌘⌃⌥R).

## Troubleshooting: no Hammerspoon item renders

If the items poll and build their menus but nothing shows in the menu bar — not
even Hammerspoon's own hammer icon — macOS has hidden the whole app.

On macOS 26 (Tahoe), ⌘-dragging **one** status item off the menu bar hides
**every** item from that app, keyed by bundle ID and stored by Control Center.
Nothing in Hammerspoon's own preferences records it, so reinstalling,
rebooting, or `defaults delete org.hammerspoon.Hammerspoon` will not bring the
items back. Menu bar managers such as Thaw or Ice move items by simulating
exactly that drag, so the combination of Hammerspoon plus a manager is the
usual way to trip it.

**Fix:** System Settings → Menu Bar, find Hammerspoon and turn it back on.
Then check the manager's hidden section — the items reappear wherever it last
put them.

**Diagnose without guessing.** Ask Control Center directly; it names every
third-party item it tracks and says whether it is blocked:

```sh
log show --last 10m --debug \
  --predicate 'process == "ControlCenter" AND category == "appStatusItems"'
```

A healthy item logs `Starting to track host`. A hidden one logs
`Starting to track blocked host`, and the moment it was hidden is marked by
`Blocking tracked application .bundle(org.hammerspoon.Hammerspoon)`.

Two instruments that will mislead you here:

- `hs.menubar:frame()` returns height 0 right after an item is created because
  layout has not happened yet. It says nothing about visibility.
- The accessibility tree still lists a blocked item with a live title, but at a
  degenerate origin (x ≈ 0, y = screen height) instead of the menu bar row
  (y ≈ 0–3). Always compare against an item from another app that you can see.
