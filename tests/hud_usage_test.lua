local hudNotifications = {}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function containsJapanese(value)
  if type(value) ~= "string" then return false end
  for _, codepoint in utf8.codes(value) do
    if (codepoint >= 0x3040 and codepoint <= 0x30ff)
        or (codepoint >= 0x3400 and codepoint <= 0x9fff) then
      return true
    end
  end
  return false
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

local function assertEnglishNotification(index, seconds, label)
  local event = hudNotifications[index]
  assert(event, label .. " notification missing")
  assert(type(event.message) == "string" and event.message:match("%a"),
    label .. " message contains English text")
  assert(not containsJapanese(event.message),
    label .. " message must not contain Japanese UI copy")
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
assertEnglishNotification(1, 2, "app launcher progress")
assertEnglishNotification(2, 2, "app launcher error")

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
assertEnglishNotification(1, 2, "utility command error")

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
assertEnglishNotification(1, 2, "window management error")

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
assertEnglishNotification(1, 2, "Finder error")

print("hud_usage_test: ok")
