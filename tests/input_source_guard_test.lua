local setSourceCalls = {}
local watchers = {}
local failNextStart = false
local failNextStop = false

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTableEqual(actual, expected, message)
  assertEqual(#actual, #expected, message .. " length")
  for index, value in ipairs(expected) do
    assertEqual(actual[index], value, message .. "[" .. index .. "]")
  end
end

local function appWithBundleID(bundleID, shouldRaise)
  return {
    bundleID = function()
      if shouldRaise then error("bundle ID unavailable") end
      return bundleID
    end,
  }
end

_G.hs = {
  application = {
    watcher = {
      activated = "activated",
      new = function(callback)
        local watcher = {
          callback = callback,
          stopped = false,
          started = false,
          failStart = failNextStart,
          failStop = failNextStop,
        }
        failNextStart = false
        failNextStop = false
        function watcher:start()
          self.started = true
          if self.failStart then
            self.started = false
            self.stopped = true
            error("injected watcher start failure")
          end
          return self
        end
        function watcher:stop()
          self.stopped = true
          if self.failStop then error("injected watcher stop failure") end
        end
        watchers[#watchers + 1] = watcher
        return watcher
      end,
    },
  },
  keycodes = {
    currentSourceID = function(sourceID)
      if sourceID ~= nil then setSourceCalls[#setSourceCalls + 1] = sourceID end
      return sourceID == nil and "com.apple.keylayout.ABC" or true
    end,
  },
}

package.path = "./?.lua;" .. package.path
local guard = require("input_source_guard")

assert(type(guard) == "table", "input_source_guard must return a module table")
assert(type(guard.start) == "function", "input_source_guard.start() must be exported")

local sourceID = "jp.monokakido.inputmethod.Kawasemi4.Roman"
local function dispatch(watcher, appName, eventType, app)
  if not watcher.stopped then watcher.callback(appName, eventType, app) end
end

local function dispatchToActiveWatchers(appName, eventType, app)
  for _, watcher in ipairs(watchers) do
    dispatch(watcher, appName, eventType, app)
  end
end

guard.start()
assertEqual(#watchers, 1, "start creates one watcher")
assertEqual(watchers[1].started, true, "start starts the watcher")

dispatch(watchers[1], "Finder", hs.application.watcher.activated, appWithBundleID("com.apple.finder"))
assertTableEqual(setSourceCalls, { sourceID }, "Finder activation selects Kawasemi 4 Roman once")

dispatch(watchers[1], "Linear", hs.application.watcher.activated, appWithBundleID("com.linear"))
assertTableEqual(setSourceCalls, { sourceID, sourceID }, "Linear activation selects Kawasemi 4 Roman once")

local callsBeforeIgnoredEvents = #setSourceCalls
dispatch(watchers[1], "Safari", hs.application.watcher.activated, appWithBundleID("com.apple.Safari"))
dispatch(watchers[1], "Finder", "launched", appWithBundleID("com.apple.finder"))
dispatch(watchers[1], "Finder", hs.application.watcher.activated, appWithBundleID(nil, true))
assertEqual(#setSourceCalls, callsBeforeIgnoredEvents, "non-target, non-activated, and unavailable bundle events do not select input source")

guard.start()
assertEqual(#watchers, 2, "restart creates one replacement watcher")
assertEqual(watchers[1].stopped, true, "restart stops the existing watcher")
assertEqual(watchers[2].started, true, "restart starts the replacement watcher")

local callsBeforeRestartDispatch = #setSourceCalls
dispatchToActiveWatchers("Finder", hs.application.watcher.activated, appWithBundleID("com.apple.finder"))
assertEqual(#setSourceCalls, callsBeforeRestartDispatch + 1, "replacement watcher selects input source once")

failNextStop = true
local stopFailureOK = pcall(function() guard.start() end)
assertEqual(stopFailureOK, true, "restart suppresses watcher stop failure")
assertEqual(watchers[2].stopped, true, "restart retires the watcher even when stop reports failure")
assertEqual(watchers[3].started, true, "restart starts a replacement after stop failure")

failNextStart = true
local startFailureOK = pcall(function() guard.start() end)
assertEqual(startFailureOK, true, "start suppresses watcher start failure")
assertEqual(watchers[3].stopped, true, "start failure retires the previous watcher")
assertEqual(watchers[4].started, false, "failed watcher is not active")

print("input_source_guard_test: ok")
