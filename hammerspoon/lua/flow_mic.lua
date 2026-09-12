-- Keeps a hardware-muted microphone usable for Wispr Flow dictation.
--
-- ⌥Space is bound here rather than in Wispr: this module unmutes the mic, then
-- synthesizes Wispr's own shortcut so Wispr starts recording. On the way back
-- out it puts the saved mute state back. Owning the trigger means both edges
-- are known without reading anything Wispr writes.
--
-- Wispr used to log its IPC messages to ~/Library/Logs/Wispr Flow, and an
-- earlier version of this tool tailed that log. As of 1.6.827 the file logging
-- is gated behind a `developmentFileLogging` flag that ships off, so the log
-- stays empty and there is nothing left to tail.
local util = require("util")

local M = {}

local BIN = os.getenv("HOME") .. "/.local/bin/"

-- Wispr Flow's own shortcut, as macOS virtual keycodes for keysend: the key
-- first, then each modifier. Left-side modifiers (⌘ 55, ⇧ 56) — Wispr
-- distinguishes left from right, and its settings UI marks a right-side
-- binding with an arrow (⌘→). Use 54/60 if you bound the right-hand keys.
local WISPR_CHORD = { "116", "55", "56" } -- ⌘⇧PageUp

-- The two edges are not symmetric, because hands-free mode is not a toggle:
-- the shortcut starts a dictation, but pressing it again does not end one.
-- This deep link does, and it is idempotent, so a stop that arrives twice (the
-- hotkey and then the watchdog) is harmless. Its start-hands-free counterpart
-- is NOT usable in the other direction — it begins recording without taking
-- Wispr's focused-element snapshot, so the transcript has nowhere to insert
-- and you get "select a textbox". Starting therefore has to be a real
-- keystroke, and only stopping can be a URL.
local WISPR_STOP_URL = "wispr-flow://stop-hands-free"

-- How often to check that the dictation we started is still running, and how
-- many misses in a row end it. The first check lands one interval in, which
-- has to be long enough for Wispr to have opened the input stream.
local WATCH_INTERVAL = 1.5
local WATCH_MISSES = 2

local dictating = false
local watchdog = nil
local misses = 0
local hotkey = nil

local function script(name, callback)
  return util.run(BIN .. name, {}, callback or function() end)
end

-- Presses Wispr's shortcut as real key events. System Events' flags-only
-- keystrokes are invisible to Wispr's shortcut listener; keysend posts
-- discrete modifier keydowns to the HID tap, which is what hardware looks
-- like. See ../../keysend.
local function pressWisprChord(callback)
  return util.run(BIN .. "keysend", WISPR_CHORD, callback or function() end)
end

-- `open -g` so Wispr does not come to the front. Insertion happens on stop, and
-- it goes to whatever is focused — activating Wispr here would aim the
-- transcript at Wispr itself.
local function stopWispr(callback)
  return util.run("/usr/bin/open", { "-g", WISPR_STOP_URL }, callback or function() end)
end

local function stopWatchdog()
  if watchdog then
    watchdog:stop()
    watchdog = nil
  end
  misses = 0
end

-- The unattended path: Wispr stopped without us, so there is no chord to send
-- and nothing to wait for before restoring. A stop we initiated restores from
-- inside toggle() instead, once its chord has landed.
local function finish()
  dictating = false
  stopWatchdog()
  script("flow-mic-enforce")
end

-- Wispr can end a dictation without us: it times out, the user clicks its
-- panel, another shortcut stops it. Polling the mic itself catches every one
-- of those, so our toggle bit can never strand the mic unmuted. A single miss
-- is tolerated because CoreAudio briefly reports the device idle between
-- Wispr's own start and stop sounds.
local function startWatchdog()
  stopWatchdog()
  watchdog = hs.timer.doEvery(WATCH_INTERVAL, function()
    script("flow-mic-active", function(code)
      if code == 0 then
        misses = 0
        return
      end
      misses = misses + 1
      if misses >= WATCH_MISSES and dictating then finish() end
    end)
  end)
end

local function toggle()
  if dictating then
    dictating = false
    stopWatchdog()
    -- Restore only once the stop has actually been delivered, not alongside
    -- it: flow-mic-enforce re-mutes within ~60ms, and muting before Wispr has
    -- seen the stop takes the tail of the dictation with it.
    stopWispr(function() script("flow-mic-enforce") end)
    return
  end

  -- Unmute and forward concurrently: measured here, flow-mic-start settles in
  -- ~220ms and a two-modifier chord takes ~270ms to finish posting (6 events
  -- 25ms apart, plus process start), and Wispr only opens the stream after
  -- that. The mic is live before there is any audio to lose, without paying
  -- for both in series.
  dictating = true
  script("flow-mic-start")
  pressWisprChord()
  startWatchdog()
end

-- ⌥Space, which macOS leaves free — ⌘Space is Spotlight's, and binding that
-- one fails with RegisterEventHotKey -9878 until Spotlight's shortcut is
-- turned off. Binding ⌥Space does cost typing a non-breaking space, since the
-- hotkey swallows the chord before any text field sees it.
local TRIGGER = { mods = { "alt" }, key = "space" }

function M.start()
  hotkey = hs.hotkey.bind(TRIGGER.mods, TRIGGER.key, toggle)

  -- bind() returns nil when something already owns the chord, and the failure
  -- only reaches the Hammerspoon console, where it looks exactly like nothing
  -- happening. Say it out loud instead.
  if not hotkey then
    hs.alert.show("flow-mic: ⌥Space is already registered — hotkey inactive", 5)
  end
end

function M.stop()
  if hotkey then
    hotkey:delete()
    hotkey = nil
  end
  -- A reload mid-dictation would otherwise leave the mic unmuted with nothing
  -- left running to put it back.
  if dictating then finish() end
  stopWatchdog()
end

return M
