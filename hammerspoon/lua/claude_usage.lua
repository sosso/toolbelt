-- Menu bar item: Claude usage against the rate limit windows of your plan.
--
-- Reads the endpoint Claude Code's own /usage renders — the OAuth token out of
-- the keychain, then GET /api/oauth/usage — rather than scraping claude.ai with
-- a browser cookie or shelling out to ccusage. That means no dependency beyond
-- the two things a Claude Code install already leaves on the machine.

local util = require("util")

local M = {}

local config = {
  defaultRefreshSeconds = 300,
  refreshChoices = { 60, 120, 300, 600, 1800 },
  usageURL = "https://api.anthropic.com/api/oauth/usage",
  keychainService = "Claude Code-credentials",
  securityPath = "/usr/bin/security",
  settingsKey = "hammerspoon.claude_usage.style",
  refreshSettingsKey = "hammerspoon.claude_usage.refreshSeconds",
  -- A window at or above `warn` colours, and starts carrying its own reset
  -- countdown in the menu bar title; at or above `crit` it turns red.
  warnPercent = 70,
  critPercent = 90,
  meterCells = 5,
  menuBarCells = 16,
  rowWidth = 62,
  rowSize = 14,
  settingsURL = "https://claude.ai/settings/usage",
}

local menubar, timer, sleepWatcher
local state = {
  limits = nil,
  plan = nil,
  spend = nil,
  error = nil,
  hint = nil,
  fetchedAt = nil,
  loading = false,
  raw = nil,
}

-- ---------------------------------------------------------------- formatting

local function toneOf(percent)
  if percent >= config.critPercent then return "red" end
  if percent >= config.warnPercent then return "orange" end
  return nil
end

local function titleColor(percent)
  local tone = toneOf(percent)
  if tone then return util.colors[tone] end
  return util.colors.secondary
end

-- A meter as two runs, because at menu bar size the fill of ▰ against ▱ is far
-- too fine to separate on shape alone — the colour split is what makes it read.
local function meterRuns(percent, cells, color)
  local on = math.floor((math.min(percent, 100) / 100) * cells + 0.5)
  return {
    { string.rep("▰", on), color },
    { string.rep("▱", cells - on), util.colors.faint },
  }
end

local function bar(percent, cells)
  local on = math.floor((math.min(percent, 100) / 100) * cells + 0.5)
  return string.rep("█", on) .. string.rep("░", cells - on)
end

local BLOCKS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local function spark(percent)
  return BLOCKS[math.min(8, math.floor(percent / 12.5) + 1)]
end

local PIES = { "○", "◔", "◑", "◕", "●" }
local function pie(percent)
  return PIES[math.min(5, math.floor(percent / 20) + 1)]
end

-- Compact time until an epoch: "42m", "4h 28m", "6d 16h".
local function untilEpoch(epoch)
  if not epoch then return nil end
  local seconds = epoch - os.time()
  if seconds <= 0 then return "due" end
  if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
  if seconds < 86400 then
    return string.format("%dh %dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
  end
  return string.format("%dd %dh", math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600))
end

-- The same, shortened to one unit, for the menu bar title.
local function untilShort(epoch)
  if not epoch then return nil end
  local seconds = epoch - os.time()
  if seconds <= 0 then return "due" end
  if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
  if seconds < 86400 then return string.format("%dh", math.floor(seconds / 3600 + 0.5)) end
  return string.format("%dd", math.floor(seconds / 86400 + 0.5))
end

local function clockAt(epoch)
  if not epoch then return nil end
  local today = os.date("*t")
  local at = os.date("*t", epoch)
  if today.yday == at.yday and today.year == at.year then
    return os.date("%H:%M", epoch)
  end
  return os.date("%a %H:%M", epoch)
end

-- ------------------------------------------------------------------- windows

-- The API's own `limits` array is the shape to render: it already carries the
-- label, ordering and severity of every window the plan has, including scoped
-- ones the account may only grow later. Reading it rather than the flat
-- five_hour/seven_day fields is what keeps a new limit from needing code here.
local function labelFor(limit)
  local scope = limit.scope or {}
  local model = scope.model and scope.model.display_name
  local surface = scope.surface and (scope.surface.display_name or scope.surface.id)

  if limit.kind == "session" then return "Session (5h)" end
  if limit.kind == "weekly_all" then return "Weekly (all)" end
  if limit.kind == "weekly_scoped" then
    return "Weekly (" .. (model or surface or "scoped") .. ")"
  end
  return (limit.kind or "limit"):gsub("_", " "):gsub("^%l", string.upper)
end

local function normalize(limits)
  local out = {}
  for _, limit in ipairs(limits or {}) do
    if limit.percent then
      table.insert(out, {
        kind = limit.kind,
        group = limit.group,
        label = labelFor(limit),
        percent = math.floor(limit.percent + 0.5),
        resetsAt = limit.resets_at and util.epochOf(limit.resets_at) or nil,
        resetsAtISO = limit.resets_at,
        locked = limit.locked_reason,
      })
    end
  end
  return out
end

-- The two windows the title speaks for. `kind` is the contract; `group` is the
-- fallback for a plan shape that names its windows something else.
local function titleWindows()
  local session, weekly
  for _, w in ipairs(state.limits or {}) do
    if w.kind == "session" or (not session and w.group == "session") then
      session = session or w
    elseif w.kind == "weekly_all" then
      weekly = w
    elseif not weekly and w.group == "weekly" then
      weekly = w
    end
  end
  return session, weekly
end

-- --------------------------------------------------------------------- style

-- Every style takes the two title windows and returns styled runs. They all
-- stay live so the menu can switch between them without a reload.
local STYLES = {
  {
    key = "cc_dual_meter",
    label = "CC ▱▱▱▱▱ 4% ▰▱▱▱▱ 8%",
    -- Two meters, one window each, with a window's reset countdown appearing
    -- only once that window is hot enough for the countdown to change what you
    -- would do about it.
    render = function(session, weekly)
      local runs = { { "CC ", util.colors.faint } }
      for _, w in ipairs({ session, weekly }) do
        if w then
          local color = titleColor(w.percent)
          for _, run in ipairs(meterRuns(w.percent, config.meterCells, color)) do
            table.insert(runs, run)
          end
          table.insert(runs, { string.format(" %d%%", w.percent), color })
          if w.percent >= config.warnPercent then
            local left = untilShort(w.resetsAt)
            if left then table.insert(runs, { " " .. left, util.colors.faint }) end
          end
          -- Two spaces, so the session's percentage and the week's meter do not
          -- read as one run of digits and blocks.
          table.insert(runs, { "  ", util.colors.faint })
        end
      end
      return runs
    end,
  },
  {
    key = "cc_dual_percent",
    label = "CC 4% 8%",
    render = function(session, weekly)
      local runs = { { "CC", util.colors.faint } }
      for _, w in ipairs({ session, weekly }) do
        if w then
          table.insert(runs, { string.format(" %d%%", w.percent), titleColor(w.percent) })
        end
      end
      return runs
    end,
  },
  {
    key = "house",
    label = "CC 4▸ 8▪",
    render = function(session, weekly)
      local runs = { { "CC", util.colors.faint } }
      if session then
        table.insert(runs, { string.format(" %d▸", session.percent), titleColor(session.percent) })
      end
      if weekly then
        table.insert(runs, { string.format(" %d▪", weekly.percent), titleColor(weekly.percent) })
      end
      return runs
    end,
  },
  {
    key = "labelled",
    label = "5h 4% · 7d 8%",
    render = function(session, weekly)
      local runs = {}
      if session then
        table.insert(runs, { "5h ", util.colors.faint })
        table.insert(runs, { session.percent .. "%", titleColor(session.percent) })
      end
      if session and weekly then table.insert(runs, { " · ", util.colors.faint }) end
      if weekly then
        table.insert(runs, { "7d ", util.colors.faint })
        table.insert(runs, { weekly.percent .. "%", titleColor(weekly.percent) })
      end
      return runs
    end,
  },
  {
    key = "worst",
    label = "⚡ 8%",
    render = function(session, weekly)
      local worst = math.max(session and session.percent or 0, weekly and weekly.percent or 0)
      return { { "⚡", util.colors.faint }, { " " .. worst .. "%", titleColor(worst) } }
    end,
  },
  {
    key = "meter",
    label = "⚡ ▰▱▱▱▱ 8%",
    render = function(_, weekly)
      if not weekly then return { { "⚡", util.colors.faint } } end
      local color = titleColor(weekly.percent)
      local runs = { { "⚡ ", util.colors.faint } }
      for _, run in ipairs(meterRuns(weekly.percent, config.meterCells, color)) do
        table.insert(runs, run)
      end
      table.insert(runs, { string.format(" %d%%", weekly.percent), color })
      return runs
    end,
  },
  {
    key = "sparks",
    label = "⚡ ▁▁",
    render = function(session, weekly)
      local runs = { { "⚡ ", util.colors.faint } }
      for _, w in ipairs({ session, weekly }) do
        if w then table.insert(runs, { spark(w.percent), titleColor(w.percent) }) end
      end
      return runs
    end,
  },
  {
    key = "dot",
    label = "⚡ ●",
    render = function(session, weekly)
      local worst = math.max(session and session.percent or 0, weekly and weekly.percent or 0)
      local tone = toneOf(worst)
      return {
        { "⚡", util.colors.faint },
        { " ●", tone and util.colors[tone] or util.colors.green },
      }
    end,
  },
  {
    key = "pie",
    label = "◔ 8%",
    render = function(_, weekly)
      if not weekly then return { { "○", util.colors.faint } } end
      local color = titleColor(weekly.percent)
      return { { pie(weekly.percent), color }, { " " .. weekly.percent .. "%", color } }
    end,
  },
  {
    key = "pressure",
    label = "⚡ 8% · 4h",
    render = function(_, weekly)
      if not weekly then return { { "⚡", util.colors.faint } } end
      local runs = {
        { "⚡", util.colors.faint },
        { " " .. weekly.percent .. "%", titleColor(weekly.percent) },
      }
      local left = untilShort(weekly.resetsAt)
      if left then
        table.insert(runs, { " · ", util.colors.faint })
        table.insert(runs, { left, util.colors.faint })
      end
      return runs
    end,
  },
  {
    key = "quiet",
    label = "⚡  (numbers only when hot)",
    render = function(session, weekly)
      local hot
      for _, w in ipairs({ session, weekly }) do
        if w and w.percent >= config.warnPercent and (not hot or w.percent > hot.percent) then
          hot = w
        end
      end
      if not hot then return { { "⚡", util.colors.faint } } end
      local runs = {
        { "⚡", titleColor(hot.percent) },
        { " " .. hot.percent .. "%", titleColor(hot.percent) },
      }
      local left = untilShort(hot.resetsAt)
      if left then table.insert(runs, { " " .. left, util.colors.faint }) end
      return runs
    end,
  },
}

local function refreshSeconds()
  local stored = hs.settings.get(config.refreshSettingsKey)
  for _, seconds in ipairs(config.refreshChoices) do
    if stored == seconds then return seconds end
  end
  return config.defaultRefreshSeconds
end

local function intervalLabel(seconds)
  if seconds < 3600 then return string.format("every %dm", seconds / 60) end
  return string.format("every %dh", seconds / 3600)
end

local function currentStyle()
  local key = hs.settings.get(config.settingsKey)
  for _, style in ipairs(STYLES) do
    if style.key == key then return style end
  end
  return STYLES[1]
end

local function updateTitle()
  if not menubar then return end

  if state.error then
    return menubar:setTitle(util.styled({
      { "CC ", util.colors.faint }, { "⚠", util.colors.red },
    }))
  end
  if not state.limits then
    return menubar:setTitle(util.styled({ { "CC …", util.colors.faint } }))
  end

  local session, weekly = titleWindows()
  local runs = currentStyle().render(session, weekly)
  if #runs == 0 then runs = { { "CC ?", util.colors.faint } } end
  menubar:setTitle(util.styled(runs))

  local lines = {}
  for _, w in ipairs(state.limits) do
    local left = untilEpoch(w.resetsAt)
    table.insert(lines, string.format("%s  %d%%%s", w.label, w.percent,
      left and ("  · resets in " .. left) or ""))
  end
  if state.plan then table.insert(lines, state.plan) end
  menubar:setTooltip(table.concat(lines, "\n"))
end

-- --------------------------------------------------------------- fetch cycle

local function fail(message, hint)
  state.error = message
  state.hint = hint
  state.limits = nil
  updateTitle()
end

local function requestUsage(token)
  hs.http.asyncGet(config.usageURL, {
    Authorization = "Bearer " .. token,
    ["anthropic-beta"] = "oauth-2025-04-20",
    Accept = "application/json",
  }, function(status, body)
    state.loading = false
    state.fetchedAt = os.time()

    if status == 401 or status == 403 then
      return fail("Claude rejected the token",
        "Its access token has expired. Run `claude` once to refresh it.")
    end
    if status ~= 200 then
      return fail("Usage request failed (HTTP " .. tostring(status) .. ")",
        status <= 0 and "No response — check the network." or nil)
    end

    local ok, decoded = pcall(hs.json.decode, body)
    if not ok or type(decoded) ~= "table" then
      return fail("Unreadable response from the usage endpoint")
    end

    local limits = normalize(decoded.limits)
    if #limits == 0 then
      return fail("No usage windows in the response",
        "The account may not have rate limits reported here.")
    end

    state.error, state.hint = nil, nil
    state.limits = limits
    state.raw = body
    state.spend = decoded.spend
    state.extra = decoded.extra_usage
    updateTitle()
  end)
end

local function refresh()
  if state.loading then return end
  state.loading = true

  util.run(config.securityPath,
    { "find-generic-password", "-s", config.keychainService, "-w" },
    function(code, out, err)
      if code ~= 0 then
        state.loading = false
        state.fetchedAt = os.time()
        local message = (err ~= "" and err or out):gsub("%s+$", "")
        -- The keychain item belongs to Claude Code, so the first read from
        -- Hammerspoon raises an authorization prompt rather than an error.
        -- Declining it lands here, and so does never having signed in.
        if message:find("interaction is not allowed") or message:find("-25308") then
          return fail("Keychain access denied",
            "Allow Hammerspoon to read the Claude Code credential, then refresh.")
        end
        return fail("No Claude credential in the keychain",
          "Sign in with `claude` — the item is called " .. config.keychainService .. ".")
      end

      local ok, decoded = pcall(hs.json.decode, out)
      local oauth = ok and decoded and decoded.claudeAiOauth
      if not oauth or not oauth.accessToken then
        state.loading = false
        return fail("Keychain credential is not in the expected shape")
      end

      state.plan = oauth.subscriptionType
        and ("Plan: " .. oauth.subscriptionType:gsub("^%l", string.upper))
        or nil
      requestUsage(oauth.accessToken)
    end)
end

local function scheduleTimer()
  if timer then timer:stop() end
  timer = hs.timer.doEvery(refreshSeconds(), refresh)
end

-- ---------------------------------------------------------------------- menu

local function windowRow(w, p)
  local percent = string.format("%3d%%", w.percent)
  local tone = toneOf(w.percent)
  local percentColor = tone and p[tone] or p.primary
  local barColor = tone and p[tone] or p.green
  local left = untilEpoch(w.resetsAt)

  return {
    title = util.row(config.rowWidth, config.rowSize, {
      { "  " .. w.label .. "  ", { color = p.primary } },
      { "", gap = true },
      { bar(w.percent, config.menuBarCells), { color = barColor } },
      { "  " .. percent .. "  ", { color = percentColor } },
      { left and ("in " .. left) or "no reset", { color = p.faint } },
      { "  " },
    }),
    tooltip = w.locked
      and ("Locked: " .. w.locked)
      or (w.resetsAtISO and ("Resets " .. (clockAt(w.resetsAt) or w.resetsAtISO)) or nil),
    disabled = true,
  }
end

local function styleMenu(p)
  local current = currentStyle()
  local rows = {}
  for _, style in ipairs(STYLES) do
    local chosen = style.key == current.key
    table.insert(rows, {
      title = util.row(34, config.rowSize, {
        { (chosen and "  ✓ " or "    ") .. style.label,
          { color = chosen and p.primary or p.secondary } },
      }),
      fn = function()
        hs.settings.set(config.settingsKey, style.key)
        updateTitle()
      end,
    })
  end
  return rows
end

local function intervalMenu(p)
  local current = refreshSeconds()
  local rows = {}
  for _, seconds in ipairs(config.refreshChoices) do
    local chosen = seconds == current
    table.insert(rows, {
      title = util.row(26, config.rowSize, {
        { (chosen and "  ✓ " or "    ") .. intervalLabel(seconds),
          { color = chosen and p.primary or p.secondary } },
        { "", gap = true },
        { seconds == config.defaultRefreshSeconds and "default  " or "  ", { color = p.faint } },
      }),
      fn = function()
        hs.settings.set(config.refreshSettingsKey, seconds)
        scheduleTimer()
      end,
    })
  end
  return rows
end

local function buildMenu()
  refresh()

  local p = util.palette()
  local items = {}

  local function line(text, color)
    return {
      title = util.row(config.rowWidth, config.rowSize,
        { { "  " .. util.truncate(text, config.rowWidth - 4), { color = color } } }),
      disabled = true,
    }
  end

  if state.error then
    table.insert(items, line(state.error, p.red))
    if state.hint then table.insert(items, line(state.hint, p.secondary)) end
  elseif not state.limits then
    table.insert(items, line("Loading…", p.faint))
  else
    for _, w in ipairs(state.limits) do
      table.insert(items, windowRow(w, p))
    end

    local notes = {}
    if state.plan then table.insert(notes, state.plan) end
    if state.extra then
      table.insert(notes, state.extra.is_enabled and "extra usage on" or "extra usage off")
    end
    if #notes > 0 then
      table.insert(items, { title = "-" })
      table.insert(items, line(table.concat(notes, " · "), p.secondary))
    end
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = util.row(config.rowWidth, config.rowSize, {
      { "  Menu bar style", { color = p.cyan } },
      { "", gap = true },
      { currentStyle().label .. "  ", { color = p.faint } },
    }),
    menu = styleMenu(p),
  })
  table.insert(items, {
    title = util.row(config.rowWidth, config.rowSize, {
      { "  Check for updates", { color = p.cyan } },
      { "", gap = true },
      { intervalLabel(refreshSeconds()) .. "  ", { color = p.faint } },
    }),
    menu = intervalMenu(p),
  })
  table.insert(items, {
    title = util.row(config.rowWidth, config.rowSize, {
      { "  Refresh now", { color = p.cyan } },
      { "", gap = true },
      { (state.fetchedAt and ("checked " .. util.agoEpoch(state.fetchedAt))
        or "never checked") .. "  ", { color = p.faint } },
    }),
    fn = refresh,
  })
  table.insert(items, {
    title = util.row(config.rowWidth, config.rowSize,
      { { "  Open usage settings", { color = p.cyan } } }),
    fn = util.openURL(config.settingsURL),
  })
  if state.raw then
    table.insert(items, {
      title = util.row(config.rowWidth, config.rowSize,
        { { "  Copy raw response", { color = p.faint } } }),
      fn = util.copy(state.raw),
    })
  end

  return items
end

-- --------------------------------------------------------------------- hooks

function M.start()
  -- The autosave name gives the item a stable identity across restarts, and is
  -- what a menu bar manager (Thaw, Ice, Bartender) lists it by.
  menubar = hs.menubar.new(true, "hammerspoon.claude_usage")
  if not menubar then return end
  menubar:setMenu(buildMenu)
  updateTitle()
  refresh()

  scheduleTimer()
  sleepWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then
      -- hs.timer is NSTimer-backed and stalls across sleep, so the repeating
      -- timer is replaced rather than trusted to pick itself back up.
      scheduleTimer()
      refresh()
    end
  end):start()
end

-- For `hs -c "hs.inspect(menus.usage.snapshot())"`.
function M.snapshot()
  local rows = {}
  for _, w in ipairs(state.limits or {}) do
    table.insert(rows, string.format("%s %d%% resets %s",
      w.label, w.percent, w.resetsAtISO or "never"))
  end
  return {
    style = currentStyle().key,
    refreshSeconds = refreshSeconds(),
    error = state.error,
    hint = state.hint,
    fetchedAt = state.fetchedAt,
    windows = rows,
  }
end

function M.popup(x, y)
  if menubar then menubar:popupMenu({ x = x or 400, y = y or 40 }) end
end

function M.stop()
  if timer then timer:stop() end
  if sleepWatcher then sleepWatcher:stop() end
  if menubar then menubar:delete() end
  menubar = nil
end

return M
