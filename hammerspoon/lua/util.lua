-- Small helpers shared by the menu bar modules.

local M = {}

function M.hex(value)
  local r, g, b = value:match("^#?(%x%x)(%x%x)(%x%x)$")
  return {
    red = tonumber(r, 16) / 255,
    green = tonumber(g, 16) / 255,
    blue = tonumber(b, 16) / 255,
  }
end

-- Dracula, and its official light counterpart Alucard.
-- https://draculatheme.com/contribute#color-palette
local DRACULA = {
  primary = M.hex("#F8F8F2"), -- foreground
  secondary = M.hex("#9AA3D0"), -- comment, lifted enough to read as a second tier
  faint = M.hex("#6272A4"), -- comment
  green = M.hex("#50FA7B"),
  red = M.hex("#FF5555"),
  orange = M.hex("#FFB86C"),
  yellow = M.hex("#F1FA8C"),
  purple = M.hex("#BD93F9"),
  cyan = M.hex("#8BE9FD"),
  pink = M.hex("#FF79C6"),
}

local ALUCARD = {
  primary = M.hex("#1F1F1F"),
  secondary = M.hex("#4C4A3E"),
  faint = M.hex("#6C664B"),
  green = M.hex("#14710A"),
  red = M.hex("#CB3A2A"),
  orange = M.hex("#A34D14"),
  yellow = M.hex("#846E15"),
  purple = M.hex("#644AC9"),
  cyan = M.hex("#036A96"),
  pink = M.hex("#A3144D"),
}

-- Menu popups follow the system theme; the menu bar itself is dark in both,
-- so titles always use Dracula.
function M.palette()
  return hs.host.interfaceStyle() == "Dark" and DRACULA or ALUCARD
end

M.colors = DRACULA

-- Builds a menu bar title from {text, color} pairs.
function M.styled(runs)
  local out = hs.styledtext.new("")
  for _, run in ipairs(runs) do
    out = out .. hs.styledtext.new(run[1], {
      color = run[2] or M.colors.faint,
      font = { name = "Menlo", size = 12 },
    })
  end
  return out
end

-- One styled run. opts: color, size, mono, bold.
--
-- `mono` switches to Menlo — it lines up number columns, and it is the only
-- way to get bold here: the system UI font has no PostScript name for its bold
-- face, so asking for one silently falls back to the regular font at the
-- default size. `bold` is therefore honoured only alongside `mono`.
function M.text(str, opts)
  opts = opts or {}
  local name = ".AppleSystemUIFont"
  if opts.mono then name = opts.bold and "Menlo-Bold" or "Menlo" end
  return hs.styledtext.new(str, {
    font = { name = name, size = opts.size or 14 },
    color = opts.color,
  })
end

function M.join(...)
  local out = hs.styledtext.new("")
  for _, part in ipairs({ ... }) do out = out .. part end
  return out
end

function M.len(str)
  return utf8.len(str) or #str
end

-- A monospaced row laid out in fixed character columns.
--
-- parts is a list of {string, opts}; `gap` marks a run that absorbs the
-- leftover width, which is how a trailing column ends up right-aligned. Every
-- run is monospaced at one size, so columns line up down the whole menu.
function M.row(width, size, parts)
  local used = 0
  for _, part in ipairs(parts) do
    if not part.gap then used = used + M.len(part[1]) end
  end

  local slack = math.max(width - used, 0)
  local out = hs.styledtext.new("")
  local padded = false

  for _, part in ipairs(parts) do
    local str = part[1]
    if part.gap then
      str = string.rep(" ", slack)
      padded = true
    end
    local opts = {}
    for k, v in pairs(part[2] or {}) do opts[k] = v end
    opts.mono = true
    opts.size = size
    out = out .. M.text(str, opts)
  end

  if not padded and slack > 0 then
    out = out .. M.text(string.rep(" ", slack), { mono = true, size = size })
  end
  return out
end

function M.findExecutable(candidates)
  for _, path in ipairs(candidates) do
    if hs.fs.attributes(path, "mode") == "file" then return path end
  end
  return nil
end

function M.openURL(url)
  return function() hs.urlevent.openURL(url) end
end

function M.copy(text)
  return function() hs.pasteboard.setContents(text) end
end

-- Opens a command in a terminal window, for the long-lived sessions (a TUI, a
-- console, a log tail) that want a window rather than a result.
--
-- Ghostty gets `open -na`, which starts a second Ghostty instance to hold the
-- window and exits again when that window closes. Its own --help states the
-- macOS CLI runs only `+actions`, and `open -a` without -n silently drops the
-- -e command, so this is the only path that works.
function M.terminal(command, target)
  return function()
    if target == "Terminal" then
      hs.osascript.applescript(string.format(
        'tell application "Terminal"\nactivate\ndo script "%s"\nend tell', command))
    elseif target == "clipboard" then
      hs.pasteboard.setContents(command)
      hs.notify.new({ title = "Command copied", informativeText = command,
        withdrawAfter = 5 }):send()
    else
      M.run("/usr/bin/open",
        { "-na", target or "Ghostty", "--args", "-e", "/bin/zsh", "-lc", command },
        function(code, _, err)
          if code ~= 0 then
            hs.notify.new({ title = "Could not open " .. (target or "Ghostty"),
              informativeText = err, withdrawAfter = 5 }):send()
          end
        end)
    end
  end
end

function M.truncate(text, limit)
  if #text <= limit then return text end
  return text:sub(1, limit - 1) .. "…"
end

-- Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's civil
-- algorithm). Going through os.time() instead would read the fields as local
-- time, and correcting that with an os.date("!*t") round trip lands an hour
-- out whenever the local zone is on DST — mktime re-applies the offset the
-- isdst=false field asked it to skip.
local function daysFromCivil(y, m, d)
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

function M.epochOf(isoTimestamp)
  local y, mo, d, h, mi, s = isoTimestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

function M.agoEpoch(epoch)
  local seconds = os.time() - epoch
  if seconds < 90 then return string.format("%ds ago", math.max(seconds, 0)) end
  if seconds < 5400 then return string.format("%dm ago", math.floor(seconds / 60)) end
  if seconds < 172800 then return string.format("%dh ago", math.floor(seconds / 3600)) end
  return string.format("%dd ago", math.floor(seconds / 86400))
end

function M.ago(isoTimestamp)
  if not isoTimestamp then return "unknown" end
  local epoch = M.epochOf(isoTimestamp)
  if not epoch then return isoTimestamp end
  return M.agoEpoch(epoch)
end

-- Runs a command off the main thread and hands the callback (exitCode, stdout, stderr).
--
-- hs.task inherits Hammerspoon's own environment, which has a bare PATH — a
-- tool that shells out to docker, git or matchlock silently reports the wrong
-- thing rather than failing, so a usable PATH is set explicitly.
function M.run(path, args, callback)
  if not path then return callback(127, "", "executable not found") end
  local task = hs.task.new(path, function(code, out, err) callback(code, out or "", err or "") end, args)
  task:setEnvironment({
    PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    HOME = os.getenv("HOME"),
    SHELL = os.getenv("SHELL") or "/bin/zsh",
    TERM = "dumb",
  })
  task:start()
  return task
end

return M
