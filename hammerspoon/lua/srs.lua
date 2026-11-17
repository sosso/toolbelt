-- Menu bar item: spaced-repetition drills that pop up at random to break a
-- focus streak — terminal line editing, lateral joins.
--
-- The cards themselves, the Leitner boxes and the streak all live in the `srs`
-- CLI (see ../../srs); this module only decides *when*. Every so often, at a
-- random interval, it picks one module that has cards due and opens a small
-- Ghostty window quizzing just that one. It holds off while a Focus is on,
-- while you are away from the keyboard or the screen is locked, and while a
-- quiz is already open.
local util = require("util")

local M = {}

local HOME = os.getenv("HOME")
local config = {
  srs = HOME .. "/.local/bin/srs",
  stateDir = HOME .. "/.local/share/srs",
  -- A one-action Shortcut (Get Current Focus) — the only way to ask macOS
  -- which Focus is on that covers scheduled and automation-started ones too.
  focusShortcut = "SRS Focus",
  focusOutput = (os.getenv("TMPDIR") or "/tmp/") .. "srs-focus.txt",
  frequencyKey = "hammerspoon.srs.frequency",
  defaultFrequency = "normal",
  -- How often a popup *may* come. One only comes when a card is due, so as
  -- cards climb from hours to weeks between reviews the popups thin out by
  -- themselves; this sets the pace while new material is being learned.
  frequencies = {
    { key = "often", label = "Every hour or so", min = 45, max = 90 },
    { key = "normal", label = "Every few hours", min = 120, max = 180 },
    { key = "rare", label = "Twice a day", min = 240, max = 300 },
    { key = "off", label = "Never — only when I ask" },
  },
  -- Popups stay inside the working week: Monday to Friday, these hours.
  workdayKey = "hammerspoon.srs.workdayOnly",
  workday = { startHour = 9, endHour = 18, days = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true } },
  -- Seconds without a keypress or mouse move before you count as away.
  idleLimit = 300,
  retryHeld = 300,
  -- When a Focus ends, the popup waits a little longer rather than landing
  -- the moment you come out of it.
  afterFocus = { 5, 15 },
  window = { cols = 100, rows = 40 },
  rowWidth = 72,
  rowSize = 14,
}

local menubar, timer, stateWatcher, sleepWatcher
local collapse = util.collapsible("hammerspoon.srs.collapsed", "◈")
local state = {
  status = nil,
  error = nil,
  nextAt = nil,
  held = nil,
  focus = nil,
  focusError = nil,
  deferredByFocus = false,
}

-- ------------------------------------------------------------------- helpers

local function frequency()
  local key = hs.settings.get(config.frequencyKey) or config.defaultFrequency
  for _, f in ipairs(config.frequencies) do
    if f.key == key then return f end
  end
  return config.frequencies[2]
end

local function workdayOnly()
  return hs.settings.get(config.workdayKey) ~= false
end

local function inWorkday(epoch)
  local t = os.date("*t", epoch)
  local w = config.workday
  return w.days[t.wday] and t.hour >= w.startHour and t.hour < w.endHour
end

-- Seconds from now until the working week next opens (0 if it is open).
local function untilWorkday()
  local now = os.time()
  if not workdayOnly() or inWorkday(now) then return 0 end
  local t = os.date("*t", now)
  for d = 0, 7 do
    local start = os.time({ year = t.year, month = t.month, day = t.day + d,
      hour = config.workday.startHour, min = 0, sec = 0 })
    if start > now and inWorkday(start) then return start - now end
  end
  return 3600
end

local function untilText(epoch)
  if not epoch then return "" end
  local s = epoch - os.time()
  if s <= 0 then return "now" end
  if s < 3600 then return string.format("in %dm", math.ceil(s / 60)) end
  if s < 172800 then return string.format("in %dh", math.floor(s / 3600)) end
  return string.format("in %dd", math.floor(s / 86400))
end

local function srs(args, callback)
  util.run(config.srs, args, callback or function() end)
end

local function anyDue()
  if not state.status then return false end
  for _, m in ipairs(state.status.modules) do
    if m.active and not m.graduated and m.due > 0 then return true end
  end
  return false
end

-- ------------------------------------------------------------------ title

local function updateTitle()
  if not menubar then return end
  local c = util.colors
  if collapse.collapsed() then
    return collapse.draw(anyDue() and c.pink or nil)
  end
  if state.error or not state.status then
    return menubar:setTitle(util.styled({ { "◈ ", c.faint }, { "?", c.red } }))
  end

  local s = state.status
  local runs = { { "◈", anyDue() and c.pink or c.faint } }
  if s.streak.days > 0 then
    table.insert(runs, { " " .. s.streak.days .. "d", s.streak.today and c.orange or c.faint })
  end
  local due = 0
  for _, m in ipairs(s.modules) do
    if m.active and not m.graduated then due = due + m.due end
  end
  if due > 0 then table.insert(runs, { " ·" .. due, c.purple }) end
  menubar:setTitle(util.styled(runs))
end

local function refresh(after)
  srs({ "status", "--json" }, function(code, out, err)
    if code ~= 0 then
      state.error = (err ~= "" and err or out):gsub("%s+$", "")
      if code == 127 then state.error = "srs not installed — run srs/install.sh" end
    else
      local ok, decoded = pcall(hs.json.decode, out)
      state.status = ok and decoded or nil
      state.error = nil
      if not ok then state.error = "could not read srs status" end
    end
    updateTitle()
    if after then after() end
  end)
end

-- ---------------------------------------------------------------- the popup

-- Each quiz is its own Ghostty instance, titled SRS.
local function quizWindow()
  for _, app in ipairs(hs.application.applicationsForBundleID("com.mitchellh.ghostty")) do
    for _, w in ipairs(app:allWindows()) do
      if w:title() == "SRS" then return w end
    end
  end
  return nil
end

-- A new Ghostty instance takes a second or two to show its window, and a
-- click that seems to do nothing gets clicked again — so a launch within this
-- many seconds of the last one is dropped.
local LAUNCH_SETTLE = 8
local lastLaunch = 0

local function launch(moduleId, opts)
  opts = opts or {}
  -- One quiz at a time: bring the open one forward rather than stacking
  -- another. `srs run` refuses a second quiz too, but only after Ghostty has
  -- already opened a window for it.
  local existing = quizWindow()
  if existing then
    existing:focus()
    return
  end
  if (state.status and state.status.running) or os.time() - lastLaunch < LAUNCH_SETTLE then return end
  lastLaunch = os.time()

  local command = config.srs .. (opts.learn and " learn" or " run")
  if moduleId then command = command .. " " .. moduleId end
  if opts.popup then command = command .. " --popup" end
  if opts.practice then command = command .. " --practice" end
  util.run("/usr/bin/open", {
    "-na", "Ghostty", "--args",
    "--title=SRS",
    -- `open -n` starts a Ghostty instance just for this window; without this
    -- it outlives the quiz and every popup leaves one more behind.
    "--quit-after-last-window-closed=true",
    "--window-width=" .. config.window.cols,
    "--window-height=" .. config.window.rows,
    "-e", "/bin/zsh", "-lc", command,
  }, function(code, _, err)
    if code ~= 0 then hs.alert.show("srs: could not open Ghostty — " .. err, 4) end
  end)
end

-- Asks the Shortcut which Focus is on. callback(name) — "" for none — or
-- callback(nil, reason) when it cannot tell, which holds popups: a quiz is
-- never worth breaking a Focus you set on purpose.
local function checkFocus(callback)
  os.remove(config.focusOutput)
  util.run("/usr/bin/shortcuts", {
    "run", config.focusShortcut, "-o", config.focusOutput, "--output-type", "public.plain-text",
  }, function(code, _, err)
    if code ~= 0 then
      return callback(nil, err:find("find") and ("no Shortcut named “" .. config.focusShortcut .. "”")
        or (err ~= "" and err or "shortcuts exited " .. code))
    end
    local f = io.open(config.focusOutput)
    local name = f and f:read("*a") or ""
    if f then f:close() end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name:lower() == "none" or name:lower() == "no focus" then name = "" end
    callback(name)
  end)
end

local schedule

local function hold(reason, seconds)
  state.held = reason
  schedule(seconds)
end

local function tryPopup()
  local f = frequency()
  if f.key == "off" then
    state.nextAt, state.held = nil, nil
    return updateTitle()
  end

  local closed = untilWorkday()
  if closed > 0 then
    -- Opening time plus a little, so it doesn't land on the stroke of nine.
    return hold("outside work hours", closed + math.random(10, 60) * 60)
  end

  refresh(function()
    local s = state.status
    if not s then return hold("srs unavailable", config.retryHeld) end
    if s.running then return hold("a quiz is open", config.retryHeld) end
    if s.snooze_until and s.snooze_until > os.time() then
      return hold("snoozed", s.snooze_until - os.time() + math.random(60, 300))
    end
    if hs.host.idleTime() > config.idleLimit then return hold("you're away", 180) end
    local session = hs.caffeinate.sessionProperties() or {}
    if session.CGSSessionScreenIsLocked then return hold("screen locked", 180) end
    if not anyDue() then
      state.held = nil
      return schedule(math.random(f.min, f.max) * 60)
    end

    checkFocus(function(focus, err)
      state.focus, state.focusError = focus, err
      if not focus then return hold("can't check Focus", config.retryHeld * 2) end
      if focus ~= "" then
        state.deferredByFocus = true
        return hold("Focus: " .. focus, config.retryHeld)
      end
      if state.deferredByFocus then
        state.deferredByFocus = false
        state.held = nil
        return schedule(math.random(config.afterFocus[1], config.afterFocus[2]) * 60)
      end

      srs({ "pick" }, function(code, out)
        state.held = nil
        local moduleId = out:match("^%s*(%S+)")
        if code == 0 and moduleId then launch(moduleId, { popup = true }) end
        schedule(math.random(f.min, f.max) * 60)
      end)
    end)
  end)
end

function schedule(seconds)
  if timer then timer:stop() end
  if frequency().key == "off" then
    state.nextAt = nil
    return
  end
  state.nextAt = os.time() + seconds
  timer = hs.timer.doAfter(seconds, tryPopup)
end

local function scheduleFresh()
  local f = frequency()
  state.held = nil
  if f.key == "off" then return schedule(0) end
  schedule(math.random(f.min, f.max) * 60)
end

-- ---------------------------------------------------------------------- menu

local function moduleMenu(m, p)
  local rows = {}
  for _, t in ipairs(m.templates) do
    local meter = t.graduated and string.rep("▰", 6)
      or string.rep("▰", t.box) .. string.rep("▱", 6 - t.box)
    local note = t.graduated and "graduated"
      or (t.seen == 0 and "new" or untilText(t.due))
    table.insert(rows, {
      title = util.row(48, config.rowSize, {
        { "  " .. meter .. "  ", { color = t.graduated and p.green or p.purple } },
        { t.title, { color = p.primary } },
        { "", gap = true },
        { note .. "  ", { color = p.faint } },
      }),
      disabled = true,
    })
  end
  table.insert(rows, { title = "-" })
  table.insert(rows, {
    title = util.row(48, config.rowSize, {
      { "  Learn", { color = p.cyan } },
      { "", gap = true },
      { "primer and every lesson  ", { color = p.faint } },
    }),
    fn = function() launch(m.id, { learn = true }) end,
  })
  table.insert(rows, {
    title = util.row(48, config.rowSize, { { "  Quiz now", { color = p.cyan } } }),
    fn = function() launch(m.id) end,
  })
  table.insert(rows, {
    title = util.row(48, config.rowSize, {
      { "  Practice", { color = p.cyan } },
      { "", gap = true },
      { "progress unchanged  ", { color = p.faint } },
    }),
    fn = function() launch(m.id, { practice = true }) end,
  })
  table.insert(rows, {
    title = util.row(48, config.rowSize, {
      { m.active and "  Pause this module" or "  Resume this module", { color = p.cyan } },
    }),
    fn = function() srs({ "toggle", m.id }, function() refresh() end) end,
  })
  table.insert(rows, {
    title = util.row(48, config.rowSize, { { "  Reset progress…", { color = p.red } } }),
    fn = function()
      local answer = hs.dialog.blockAlert("Reset " .. m.title .. "?",
        "Every card goes back to the first box. The streak is kept.", "Reset", "Cancel")
      if answer == "Reset" then srs({ "reset", m.id }, function() refresh() end) end
    end,
  })
  return rows
end

local function frequencyMenu(p)
  local current = frequency()
  local rows = {}
  for _, f in ipairs(config.frequencies) do
    local chosen = f.key == current.key
    local range = f.min and string.format("%d–%dm", f.min, f.max) or ""
    table.insert(rows, {
      title = util.row(36, config.rowSize, {
        { (chosen and "  ✓ " or "    ") .. f.label, { color = chosen and p.primary or p.secondary } },
        { "", gap = true },
        { range .. "  ", { color = p.faint } },
      }),
      fn = function()
        hs.settings.set(config.frequencyKey, f.key)
        scheduleFresh()
      end,
    })
  end
  return rows
end

local function buildMenu()
  refresh()
  local p = util.palette()
  local items = {}
  local W, S = config.rowWidth, config.rowSize

  local function line(text, color)
    return { title = util.row(W, S, { { "  " .. util.truncate(text, W - 4), { color = color } } }), disabled = true }
  end

  if state.error then
    table.insert(items, line(state.error, p.red))
  elseif not state.status then
    table.insert(items, line("Loading…", p.faint))
  else
    local s = state.status
    local streak = s.streak.days == 0 and "No streak yet"
      or string.format("Streak %d day%s", s.streak.days, s.streak.days == 1 and "" or "s")
    table.insert(items, {
      title = util.row(W, S, {
        { "  " .. streak, { color = s.streak.today and p.orange or p.primary } },
        { s.streak.today and "" or (s.streak.days > 0 and "  — not yet today" or ""), { color = p.faint } },
        { "", gap = true },
        { "best " .. s.streak.best .. "  ", { color = p.faint } },
      }),
      disabled = true,
    })

    local next
    if frequency().key == "off" then
      next = "Popups off"
    elseif state.held then
      next = "Holding — " .. state.held
    elseif state.nextAt then
      next = "Next popup " .. untilText(state.nextAt)
    end
    if next then table.insert(items, line(next, p.secondary)) end

    table.insert(items, { title = "-" })
    for _, m in ipairs(s.modules) do
      local note, color
      if m.graduated then
        note, color = "🎓 graduated", p.green
      elseif not m.active then
        note, color = "paused", p.faint
      elseif m.due > 0 then
        note, color = m.due .. " due", p.pink
      else
        note, color = m.next_due and ("next " .. untilText(m.next_due)) or "up to date", p.faint
      end
      table.insert(items, {
        title = util.row(W, S, {
          { "  " .. m.title, { color = m.active and p.primary or p.faint } },
          { string.format("  %d/%d mastered", m.mastered, m.total), { color = p.faint } },
          { "", gap = true },
          { note .. "  ", { color = color } },
        }),
        menu = moduleMenu(m, p),
      })
    end
    if not s.duckdb then
      table.insert(items, line("Lateral joins need DuckDB — brew install duckdb", p.orange))
    end
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = util.row(W, S, { { "  Quiz me now", { color = p.cyan } } }),
    fn = function() launch(nil) end,
  })
  local snoozed = state.status and state.status.snooze_until and state.status.snooze_until > os.time()
  table.insert(items, {
    title = util.row(W, S, {
      { snoozed and "  Stop snoozing" or "  Snooze for an hour", { color = p.cyan } },
      { "", gap = true },
      { snoozed and ("until " .. os.date("%H:%M", math.floor(state.status.snooze_until)) .. "  ") or "", { color = p.faint } },
    }),
    fn = function()
      srs({ "snooze", snoozed and "0" or "60" }, function()
        refresh(function() if snoozed then scheduleFresh() else tryPopup() end end)
      end)
    end,
  })
  table.insert(items, {
    title = util.row(W, S, {
      { "  Popups", { color = p.cyan } },
      { "", gap = true },
      { frequency().label .. "  ", { color = p.faint } },
    }),
    menu = frequencyMenu(p),
  })
  local w = config.workday
  table.insert(items, {
    title = util.row(W, S, {
      { "  Only during the work week", { color = p.cyan } },
      { "", gap = true },
      { string.format("Mon–Fri %d:00–%d:00  ", w.startHour, w.endHour), { color = p.faint } },
    }),
    checked = workdayOnly(),
    fn = function()
      hs.settings.set(config.workdayKey, not workdayOnly())
      scheduleFresh()
    end,
  })
  local focusNote = state.focusError and ("can't tell — " .. state.focusError)
    or (state.focus == nil and "not checked yet")
    or (state.focus == "" and "none on" or state.focus)
  table.insert(items, {
    title = util.row(W, S, {
      { "  Focus", { color = state.focusError and p.orange or p.cyan } },
      { "", gap = true },
      { util.truncate(focusNote, W - 14) .. "  ", { color = state.focusError and p.orange or p.faint } },
    }),
    tooltip = "Popups wait while a Focus is on. Checked through the Shortcut “"
      .. config.focusShortcut .. "” (one action: Get Current Focus). Click to check now.",
    fn = function()
      checkFocus(function(focus, err) state.focus, state.focusError = focus, err end)
    end,
  })
  table.insert(items, collapse.menuItem(p, W, S))
  return items
end

-- --------------------------------------------------------------------- hooks

function M.start()
  math.randomseed(os.time())
  menubar = hs.menubar.new(true, "hammerspoon.srs")
  if not menubar then return end
  collapse.attach(menubar, buildMenu, updateTitle)
  refresh()
  scheduleFresh()

  -- A finished quiz rewrites the state file; redraw from it straight away
  -- rather than leaving the due count stale until the next popup.
  hs.fs.mkdir(config.stateDir)
  stateWatcher = hs.pathwatcher.new(config.stateDir, function() refresh() end):start()

  sleepWatcher = hs.caffeinate.watcher.new(function(event)
    -- hs.timer stalls across sleep, so the pending popup is rescheduled
    -- instead of trusted to fire.
    if event == hs.caffeinate.watcher.systemDidWake then
      refresh()
      scheduleFresh()
    end
  end):start()
end

-- For `hs -c "hs.inspect(menus.srs.snapshot())"`, and `menus.srs.tryPopup()`
-- to test the popup path without waiting for the timer.
function M.snapshot()
  return {
    frequency = frequency().key,
    nextAt = state.nextAt and os.date("%H:%M:%S", state.nextAt),
    held = state.held,
    focus = state.focus,
    focusError = state.focusError,
    error = state.error,
    due = anyDue(),
  }
end

M.tryPopup = tryPopup
M.launch = launch

function M.stop()
  if timer then timer:stop() end
  if stateWatcher then stateWatcher:stop() end
  if sleepWatcher then sleepWatcher:stop() end
  if menubar then menubar:delete() end
  menubar = nil
end

return M
