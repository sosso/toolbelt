-- Hammerspoon config. Menu bar items live in their own modules.

hs.console.darkMode(true)
hs.window.animationDuration = 0

-- Enables `hs -c "…"` from a shell. The binary itself is linked by the
-- Homebrew cask, so this only loads the module — calling hs.ipc.cliInstall()
-- here instead fights that symlink and logs "incomplete installation of 'hs'".
-- Note the interactive `hs` alias to `heroku status` shadows it in zsh, so
-- call /opt/homebrew/bin/hs by absolute path.
require("hs.ipc")

-- Modules are installed from two places — the public ones from toolbelt, the
-- work-specific ones from the RealScoutV2 checkout — so any of them can be
-- absent. Only "module not found" is tolerated: a syntax error in a module
-- that *is* installed must still be reported, since silently skipping it looks
-- exactly like not having installed it.
local function optionalModule(name)
  local ok, module = pcall(require, name)
  if ok then return module end
  if tostring(module):find("module '" .. name .. "' not found") then return nil end
  hs.showError(module)
  return nil
end

menus = {}
for key, name in pairs({
  github = "github_prs",
  usage = "claude_usage",
  remy = "remy",
  fleet = "rsv2_fleet",
}) do
  local module = optionalModule(name)
  if module then menus[key] = module end
end

for _, m in pairs(menus) do m.start() end

-- The pathwatcher below reloads on every save, and a reload does not stop the
-- timers and watchers the previous load started — they leak until the process
-- exits. Tearing them down here is what keeps a long editing session from
-- accumulating duplicate pollers.
hs.shutdownCallback = function()
  for _, m in pairs(menus) do m.stop() end
end

-- Reload on any change to a .lua file in this directory.
local function onConfigChange(paths)
  for _, p in ipairs(paths) do
    if p:sub(-4) == ".lua" then return hs.reload() end
  end
end
configWatcher = hs.pathwatcher.new(hs.configdir, onConfigChange):start()

hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "R", hs.reload)

hs.alert.show("Hammerspoon config loaded")
