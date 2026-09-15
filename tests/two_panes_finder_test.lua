local alerts = {}
local osascriptCalls = {}
local timers = {}
local eventLog = {}
local finderWindows = {}
local pendingCreatedWindows = 0
local nextWindowId = 100
local filterCalls = 0
local frontmostMode = "window"
local mainScreenFrame = { x = 0, y = 24, w = 1440, h = 876 }
local frontmostScreenFrame = { x = 100, y = 50, w = 1001, h = 700 }
local osascriptMode = "success"
local filterMode = "normal"

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function copyFrame(frame)
  return { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
end

local function assertFrame(actual, expected, message)
  assert(actual, message .. ": missing frame")
  for _, field in ipairs({ "x", "y", "w", "h" }) do
    assertEqual(actual[field], expected[field], message .. "." .. field)
  end
end

local function makeScreen(frame)
  return { frame = function() return copyFrame(frame) end }
end

local function removeWindow(target)
  for index, window in ipairs(finderWindows) do
    if window == target then table.remove(finderWindows, index); return true end
  end
  return false
end

local function makeWindow(id)
  local window = { id = id, closed = false, setFrames = {} }
  function window:setFrame(frame, duration)
    assertEqual(duration, 0, "Finder setFrame duration")
    local value = copyFrame(frame)
    self.setFrames[#self.setFrames + 1] = value
    eventLog[#eventLog + 1] = { kind = "setFrame", id = self.id, frame = value }
    return true
  end
  function window:close()
    self.closed = true
    eventLog[#eventLog + 1] = { kind = "close", id = self.id }
    removeWindow(self)
    return true
  end
  return window
end

local function resetWindows(count)
  finderWindows = {}
  nextWindowId = 100
  for _ = 1, count do
    nextWindowId = nextWindowId + 1
    finderWindows[#finderWindows + 1] = makeWindow(nextWindowId)
  end
end

local function applyPendingWindows()
  while pendingCreatedWindows > 0 do
    nextWindowId = nextWindowId + 1
    finderWindows[#finderWindows + 1] = makeWindow(nextWindowId)
    pendingCreatedWindows = pendingCreatedWindows - 1
  end
end

local function clearState(windowCount)
  alerts = {}
  osascriptCalls = {}
  timers = {}
  eventLog = {}
  pendingCreatedWindows = 0
  filterCalls = 0
  frontmostMode = "window"
  osascriptMode = "success"
  filterMode = "normal"
  mainScreenFrame = { x = 0, y = 24, w = 1440, h = 876 }
  frontmostScreenFrame = { x = 100, y = 50, w = 1001, h = 700 }
  resetWindows(windowCount or 0)
end

local function fireNextTimer()
  local timer = table.remove(timers, 1)
  assert(timer, "expected a pending timer")
  assertEqual(timer.stopped, false, "timer must be active before firing")
  applyPendingWindows()
  timer.fired = true
  timer.callback()
  return timer
end

local finderApplication = {
  activate = function()
    eventLog[#eventLog + 1] = { kind = "activate" }
    return true
  end,
  allWindows = function()
    error("Two-panes Finder must not use hs.application:allWindows() as Finder every-window semantics")
  end,
}

_G.hs = {
  alert = { show = function(message, duration) alerts[#alerts + 1] = { message = message, duration = duration } end },
  application = {
    get = function(name) if name == "Finder" then return finderApplication end return nil end,
    find = function(name) if name == "Finder" then return finderApplication end return nil end,
    launchOrFocus = function(name)
      assertEqual(name, "Finder", "launchOrFocus app")
      eventLog[#eventLog + 1] = { kind = "activate" }
      return true
    end,
  },
  screen = { mainScreen = function() return makeScreen(mainScreenFrame) end },
  window = {
    frontmostWindow = function()
      if frontmostMode == "error" then error("frontmost window lookup failed") end
      if frontmostMode == "nil" then return nil end
      return {
        screen = function()
          if frontmostMode == "screen-error" then error("frontmost screen lookup failed") end
          if frontmostMode == "screen-nil" then return nil end
          return makeScreen(frontmostScreenFrame)
        end,
      }
    end,
    filter = {
      new = function(_)
        local filter = {}
        function filter:setAppFilter(name, rules)
          assertEqual(name, "Finder", "Finder window filter app")
          if type(rules) == "table" and rules.currentSpace ~= nil then
            error("Finder window filter must not limit enumeration to currentSpace")
          end
          return self
        end
        function filter:getWindows()
          filterCalls = filterCalls + 1
          if filterMode == "error" then error("Finder window filter failed") end
          if filterMode == "nil" then return nil end
          local copy = {}
          for index, window in ipairs(finderWindows) do copy[index] = window end
          return copy
        end
        return filter
      end,
    },
  },
  osascript = {
    applescript = function(source)
      osascriptCalls[#osascriptCalls + 1] = source
      if osascriptMode == "error" then error("osascript failure") end
      if osascriptMode == "false" then return false, nil, "injected failure" end
      if source:find("make new Finder window to desktop", 1, true) then
        pendingCreatedWindows = pendingCreatedWindows + 1
        return true, true, nil
      end
      if source:find("close", 1, true) then
        while #finderWindows > 2 do table.remove(finderWindows, 3) end
        return true, true, nil
      end
      return true, true, nil
    end,
  },
  timer = {
    doAfter = function(delay, callback)
      assert(type(delay) == "number" and delay > 0, "bounded retry delay must be positive")
      local timer = { delay = delay, callback = callback, stopped = false, fired = false }
      function timer:stop() self.stopped = true end
      timers[#timers + 1] = timer
      return timer
    end,
    stop = function(timer) timer:stop() end,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path

local moduleOK, twoPanesFinder = pcall(require, "actions.two_panes_finder")
assert(moduleOK, "actions.two_panes_finder must exist: " .. tostring(twoPanesFinder))
assert(type(twoPanesFinder) == "table", "actions.two_panes_finder must return a module table")
assert(type(twoPanesFinder.run) == "function", "two_panes_finder.run() must be exported")
assert(type(twoPanesFinder.stop) == "function", "two_panes_finder.stop() must be exported")

local function lastEventKind()
  return eventLog[#eventLog] and eventLog[#eventLog].kind or nil
end

clearState(2)
local first, second = finderWindows[1], finderWindows[2]
assertEqual(twoPanesFinder.run(), true, "two-window fast path starts")
assertEqual(#osascriptCalls, 0, "two-window fast path does not use AppleScript")
assertEqual(#timers, 0, "two-window fast path does not wait")
assertFrame(first.setFrames[1], { x = 100, y = 50, w = 500, h = 700 }, "left fast-path frame")
assertFrame(second.setFrames[1], { x = 600, y = 50, w = 501, h = 700 }, "right fast-path frame")
assertEqual(lastEventKind(), "activate", "Finder activates after fast-path placement")

clearState(2)
frontmostMode = "nil"
first, second = finderWindows[1], finderWindows[2]
assertEqual(twoPanesFinder.run(), true, "main-screen fallback starts")
assertFrame(first.setFrames[1], { x = 0, y = 24, w = 720, h = 876 }, "fallback left frame")
assertFrame(second.setFrames[1], { x = 720, y = 24, w = 720, h = 876 }, "fallback right frame")
assertEqual(#osascriptCalls, 0, "screen fallback does not require AppleScript when two Finder windows exist")

clearState(1)
first = finderWindows[1]
assertEqual(twoPanesFinder.run(), true, "one-window path starts")
assertEqual(#osascriptCalls, 1, "one-window path creates one Finder window")
assert(osascriptCalls[1]:find("make new Finder window to desktop", 1, true), "created Finder window targets Desktop")
assertEqual(#timers, 1, "one-window path waits for Finder window-count change")
assertEqual(#first.setFrames, 0, "one-window path does not lay out before new window is observable")
fireNextTimer()
assertEqual(#finderWindows, 2, "one-window path reaches two Finder windows")
assertFrame(finderWindows[1].setFrames[1], { x = 100, y = 50, w = 500, h = 700 }, "one-window left frame")
assertFrame(finderWindows[2].setFrames[1], { x = 600, y = 50, w = 501, h = 700 }, "one-window right frame")
assertEqual(lastEventKind(), "activate", "Finder activates after one-window completion")

clearState(0)
assertEqual(twoPanesFinder.run(), true, "zero-window path starts")
assertEqual(#osascriptCalls, 2, "zero-window path creates exactly two Finder windows")
for index, source in ipairs(osascriptCalls) do
  assert(source:find("make new Finder window to desktop", 1, true), "zero-window create " .. index .. " targets Desktop")
end
assertEqual(#timers, 1, "zero-window path uses bounded polling")
fireNextTimer()
assertEqual(#finderWindows, 2, "zero-window path reaches two Finder windows")
assertFrame(finderWindows[1].setFrames[1], { x = 100, y = 50, w = 500, h = 700 }, "zero-window left frame")
assertFrame(finderWindows[2].setFrames[1], { x = 600, y = 50, w = 501, h = 700 }, "zero-window right frame")

clearState(4)
local keptLeft, keptRight = finderWindows[1], finderWindows[2]
assertEqual(twoPanesFinder.run(), true, "excess-window path starts")
assertEqual(#finderWindows, 2, "excess-window path leaves exactly two Finder windows")
assertEqual(finderWindows[1], keptLeft, "excess-window path preserves first Finder window")
assertEqual(finderWindows[2], keptRight, "excess-window path preserves second Finder window")
assertFrame(keptLeft.setFrames[1], { x = 100, y = 50, w = 500, h = 700 }, "excess-window left frame")
assertFrame(keptRight.setFrames[1], { x = 600, y = 50, w = 501, h = 700 }, "excess-window right frame")
assertEqual(lastEventKind(), "activate", "Finder activates after excess-window cleanup")

clearState(2)
filterMode = "error"
local beforeAlerts = #alerts
local runOK, runResult = pcall(twoPanesFinder.run)
assertEqual(runOK, true, "window-enumeration failure is handled without raising")
assertEqual(runResult, false, "window-enumeration failure returns false")
assertEqual(#alerts, beforeAlerts + 1, "window-enumeration failure notifies once")

clearState(1)
first = finderWindows[1]
assertEqual(twoPanesFinder.run(), true, "pending path starts before stop")
assertEqual(#timers, 1, "pending path has a retry timer")
local pendingTimer = timers[1]
twoPanesFinder.stop()
assertEqual(pendingTimer.stopped, true, "stop cancels pending retry")
assertEqual(#first.setFrames, 0, "stop leaves existing Finder window untouched before retry")

local config = require("hotkeys_config")
local finderBinding
for _, binding in ipairs(config) do
  local modifiers = {}
  for index, modifier in ipairs(binding.modifiers or {}) do modifiers[index] = modifier end
  table.sort(modifiers)
  if table.concat(modifiers, "+") == "alt+cmd+shift" and binding.key == "f" then finderBinding = binding; break end
end
assert(finderBinding, "Cmd+Opt+Shift+F binding must exist")
assertEqual(finderBinding.action.type, "two_panes_finder", "Finder hotkey uses dedicated action")
assertEqual(finderBinding.action.executablePath, nil, "Finder hotkey has no external executable")
assertEqual(finderBinding.action.scriptPath, nil, "Finder hotkey has no Raycast script path")

local utilityFile = assert(io.open("actions/utility_command.lua", "r"))
local utilitySource = utilityFile:read("*a")
utilityFile:close()
assert(not utilitySource:find("two%-panes%-finder%.applescript"), "utility_command.lua must not contain Two-panes Finder special casing")

print("two_panes_finder_test: ok")
