local alerts = {}
local timers = {}
local finderWindows = {}
local pendingCreatedWindows = 0
local nextWindowId = 200
local frontmostMode = "window"
local materializePending = true
local mainScreenFrame = { x = 0, y = 24, w = 1440, h = 876 }
local frontmostScreenFrame = { x = 100, y = 50, w = 1001, h = 700 }

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

local function makeWindow(id, target)
  local window = { id = id, target = target, setFrames = {} }
  function window:setFrame(frame, duration)
    assertEqual(duration, 0, "Finder setFrame duration")
    self.setFrames[#self.setFrames + 1] = copyFrame(frame)
    return true
  end
  function window:close()
    for index, candidate in ipairs(finderWindows) do
      if candidate == self then table.remove(finderWindows, index); break end
    end
    return true
  end
  return window
end

local function resetWindows(count)
  finderWindows = {}
  nextWindowId = 200
  for _ = 1, count do
    nextWindowId = nextWindowId + 1
    finderWindows[#finderWindows + 1] = makeWindow(nextWindowId, "Original-" .. nextWindowId)
  end
end

local function reset(count)
  alerts = {}
  timers = {}
  pendingCreatedWindows = 0
  frontmostMode = "window"
  materializePending = true
  mainScreenFrame = { x = 0, y = 24, w = 1440, h = 876 }
  frontmostScreenFrame = { x = 100, y = 50, w = 1001, h = 700 }
  resetWindows(count or 0)
end

local function materializePendingWindows()
  while pendingCreatedWindows > 0 do
    nextWindowId = nextWindowId + 1
    finderWindows[#finderWindows + 1] = makeWindow(nextWindowId, "Desktop")
    pendingCreatedWindows = pendingCreatedWindows - 1
  end
end

local function fireNextTimer()
  local timer = table.remove(timers, 1)
  assert(timer, "expected a pending timer")
  assertEqual(timer.stopped, false, "timer is active before firing")
  if materializePending then materializePendingWindows() end
  timer.callback()
end

local finderApplication = {
  activate = function() return true end,
  allWindows = function()
    error("Two-panes Finder must not use hs.application:allWindows() as Finder every-window semantics")
  end,
}

_G.hs = {
  alert = {
    show = function(message, duration)
      alerts[#alerts + 1] = { message = message, duration = duration }
    end,
  },
  application = {
    get = function(name) if name == "Finder" then return finderApplication end return nil end,
    find = function(name) if name == "Finder" then return finderApplication end return nil end,
    launchOrFocus = function(name) return name == "Finder" end,
  },
  screen = {
    mainScreen = function() return makeScreen(mainScreenFrame) end,
  },
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
      sortByCreated = "sortByCreated",
      sortByCreatedLast = "sortByCreatedLast",
      sortByFocused = "sortByFocused",
      sortByFocusedLast = "sortByFocusedLast",
      new = function(_)
        local filter = {}
        function filter:setAppFilter(_, _) return self end
        function filter:setDefaultFilter(_) return self end
        function filter:setOverrideFilter(_) return self end
        function filter:setCurrentSpace(_) return self end
        function filter:setSortOrder(_) return self end
        function filter:getWindows()
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
      local lowered = string.lower(source or "")
      if lowered:find("set target", 1, true) then
        for _, window in ipairs(finderWindows) do window.target = "Desktop" end
      end
      if source and source:find("make new Finder window to desktop", 1, true) then
        pendingCreatedWindows = pendingCreatedWindows + 1
      end
      return true, true, nil
    end,
  },
  timer = {
    doAfter = function(delay, callback)
      assert(type(delay) == "number" and delay > 0, "retry delay must be positive")
      local timer = { delay = delay, callback = callback, stopped = false }
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
assert(type(twoPanesFinder.run) == "function", "two_panes_finder.run() must be exported")
assert(type(twoPanesFinder.stop) == "function", "two_panes_finder.stop() must be exported")

for _, mode in ipairs({ "nil", "error", "screen-nil", "screen-error" }) do
  reset(2)
  frontmostMode = mode
  local first, second = finderWindows[1], finderWindows[2]
  assertEqual(twoPanesFinder.run(), true, "main-screen fallback starts for " .. mode)
  assertFrame(first.setFrames[1], { x = 0, y = 24, w = 720, h = 876 }, "fallback left frame for " .. mode)
  assertFrame(second.setFrames[1], { x = 720, y = 24, w = 720, h = 876 }, "fallback right frame for " .. mode)
end

reset(1)
local originalWindow = finderWindows[1]
local originalTarget = originalWindow.target
assertEqual(twoPanesFinder.run(), true, "one-window target-preservation path starts")
assertEqual(originalWindow.target, originalTarget, "existing Finder target is unchanged before creation becomes observable")
assertEqual(#timers, 1, "one-window path waits for the new window")
fireNextTimer()
assertEqual(#finderWindows, 2, "one-window path reaches two windows")
assertEqual(finderWindows[1], originalWindow, "existing Finder window is preserved")
assertEqual(originalWindow.target, originalTarget, "existing Finder target remains unchanged")
assertEqual(finderWindows[2].target, "Desktop", "only the newly created Finder window targets Desktop")

reset(1)
materializePending = false
assertEqual(twoPanesFinder.run(), true, "bounded-retry failure path starts")
local fired = 0
local guard = 100
while #timers > 0 and fired < guard do
  fireNextTimer()
  fired = fired + 1
end
assert(fired < guard, "bounded retry stops before the safety guard")
assertEqual(#timers, 0, "bounded retry leaves no pending timer after exhaustion")
assert(#alerts >= 1, "bounded retry exhaustion notifies failure")
assertEqual(#finderWindows[1].setFrames, 0, "bounded retry exhaustion does not place an incomplete window set")

twoPanesFinder.stop()
print("two_panes_finder_edge_test: ok")
