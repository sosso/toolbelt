-- A batarang in the menu bar that blacks out the built-in display and leaves
-- the glasses alone. Click to toggle: outlined is off, solid is blacked out.
--
-- The darkening itself is done by the `blackout` helper (see ../../blackout),
-- which has to stay running for as long as the screen should stay dark: the
-- moment it exits, macOS restores the panel. So toggling on is starting it and
-- toggling off is ending it, and anything that ends it — the click, a reload,
-- the glasses being unplugged — brings the built-in back.
local util = require("util")

local M = {}

local BIN = os.getenv("HOME") .. "/.local/bin/blackout"

-- Right half of the batarang, x outward from the centre line and y down from
-- the ear tips; the left half is its mirror image.
local HALF = {
  { 0, 2.6 }, { 0.9, 2.2 }, { 1.3, 0 }, { 1.9, 2.5 }, { 5, 2.3 }, { 9, 1.4 }, { 12.5, 0 },
  { 10.6, 3.4 }, { 9.6, 6.4 }, { 7.2, 5.6 }, { 4.6, 6.6 }, { 2.6, 9.4 }, { 0, 6.8 },
}
local ICON = { w = 24, h = 16, scale = 0.9 }

local task = nil
local item = nil

local function batarang(solid)
  local cx = ICON.w / 2
  local top = (ICON.h - 9.4 * ICON.scale) / 2
  local points = {}
  for _, p in ipairs(HALF) do
    points[#points + 1] = { x = cx + p[1] * ICON.scale, y = top + p[2] * ICON.scale }
  end
  for i = #HALF - 1, 2, -1 do
    points[#points + 1] = { x = cx - HALF[i][1] * ICON.scale, y = top + HALF[i][2] * ICON.scale }
  end

  local canvas = hs.canvas.new({ x = 0, y = 0, w = ICON.w, h = ICON.h })
  canvas[1] = {
    type = "segments",
    closed = true,
    coordinates = points,
    action = solid and "fill" or "stroke",
    fillColor = { white = 0 },
    strokeColor = { white = 0 },
    strokeWidth = 1,
  }
  local image = canvas:imageFromCanvas()
  canvas:delete()
  return image
end

local function render()
  if not item then return end
  item:setIcon(batarang(task ~= nil), true)
  item:setTooltip(task and "Built-in display blacked out — click to restore"
    or "Click to black out the built-in display")
end

local function toggle()
  if task then
    task:terminate()
    return
  end

  if not hs.fs.attributes(BIN) then
    hs.alert.show("blackout: helper not installed — run blackout/install.sh", 4)
    return
  end

  task = util.run(BIN, {}, function(code, _, err)
    task = nil
    render()
    if code ~= 0 then hs.alert.show(err ~= "" and err or "blackout exited with " .. code, 4) end
  end)
  render()
end

function M.start()
  -- A helper orphaned by a Hammerspoon crash would hold the panel dark with no
  -- menu bar item left that knows about it.
  util.run("/usr/bin/pkill", { "-x", "blackout" }, function() end)

  item = hs.menubar.new()
  item:setClickCallback(toggle)
  render()
end

function M.stop()
  if task then task:terminate() end
  if item then
    item:delete()
    item = nil
  end
end

return M
