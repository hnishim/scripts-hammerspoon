local hudNotifications = {}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function resetModules(...)
  for _, name in ipairs({ ... }) do package.loaded[name] = nil end
end

package.path = "./?.lua;" .. package.path
package.preload["components.hud"] = function()
  return {
    showTransient = function(message, seconds)
      hudNotifications[#hudNotifications + 1] = { message = message, seconds = seconds }
      return { index = #hudNotifications }
    end,
  }
end

local function resetNotifications()
  hudNotifications = {}
end

local function assertNotification(index, message, seconds, label)
  local event = hudNotifications[index]
  assert(event, label .. " notification missing")
  assertEqual(event.message, message, label .. " message")
  assertEqual(event.seconds, seconds, label .. " duration")
end

-- app_launcher: launch status and generic error both use the shared HUD.
resetNotifications()
_G.hs = {
  alert = { show = function() error("app_launcher must not use hs.alert") end },
  application = {
    launchOrFocus = function() return false end,
  },
}
resetModules("actions.app_launcher")
local appLauncher = require("actions.app_launcher")
assertEqual(appLauncher.run("Missing App"), false, "failed app launch returns false")
assertEqual(#hudNotifications, 2, "failed app launch emits launch and error HUDs")
assertNotification(1, "Launching Missing App...", 2, "app launcher progress")
assertNotification(2, "Command failed.", 2, "app launcher error")

-- utility_command: task failure uses the shared English HUD.
resetNotifications()
_G.hs = {
  alert = { show = function() error("utility_command must not use hs.alert") end },
  task = {
    new = function(_, callback)
      return {
        start = function()
          callback(1, "SECRET", "details")
          return true
        end,
        terminate = function() end,
      }
    end,
  },
  window = {
    frontmostWindow = function() return nil end,
  },
}
resetModules("actions.utility_command")
local utilityCommand = require("actions.utility_command")
assertEqual(utilityCommand.run("/dev/null", "/dev/null"), true, "utility task starts before asynchronous failure")
assertEqual(#hudNotifications, 1, "utility task failure emits one HUD")
assertNotification(1, "Command failed.", 2, "utility command error")

-- window_management: boundary failure uses the shared English HUD.
resetNotifications()
_G.hs = {
  alert = { show = function() error("window_management must not use hs.alert") end },
  window = {
    frontmostWindow = function() return nil end,
  },
  timer = {
    stop = function() end,
  },
}
resetModules("actions.window_management")
local windowManagement = require("actions.window_management")
assertEqual(windowManagement.run("full"), false, "window lookup failure returns false")
assertEqual(#hudNotifications, 1, "window lookup failure emits one HUD")
assertNotification(1, "Command failed.", 2, "window management error")

-- file_name_copy: Finder acquisition failure uses the shared English HUD.
resetNotifications()
_G.hs = {
  alert = { show = function() error("file_name_copy must not use hs.alert") end },
  application = {
    frontmostApplication = function()
      return {
        name = function() return "Finder" end,
      }
    end,
  },
  osascript = {
    applescript = function() return false, nil end,
  },
}
resetModules("actions.file_name_copy")
local fileNameCopy = require("actions.file_name_copy")
assertEqual(fileNameCopy.run(), false, "Finder acquisition failure returns false")
assertEqual(#hudNotifications, 1, "Finder acquisition failure emits one HUD")
assertNotification(1, "Could not get selected Finder items.", 2, "Finder error")

print("hud_usage_test: ok")
