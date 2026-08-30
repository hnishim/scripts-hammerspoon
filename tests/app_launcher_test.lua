local launchCalls = {}
local hudEvents = {}
local alertCalls = {}
local launchResults = {}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTableEqual(actual, expected, message)
  assertEqual(#actual, #expected, message .. " length")
  for index, value in ipairs(expected) do
    assertEqual(actual[index], value, string.format("%s[%d]", message, index))
  end
end

local function dirname(path)
  return (path:gsub("[/\\][^/\\]+$", ""))
end

local function splitTabSeparated(line)
  local fields = {}
  for field in string.gmatch(line, "([^\t]+)") do fields[#fields + 1] = field end
  return fields
end

local function loadFixtureApps()
  local source = debug.getinfo(1, "S").source
  local scriptPath = source:sub(1, 1) == "@" and source:sub(2) or source
  local fixturePath = dirname(scriptPath) .. "/fixtures/launch_apps.tsv"
  local handle = assert(io.open(fixturePath, "r"), "fixture must be readable: " .. fixturePath)
  local rows = {}
  local lineNumber = 0
  for line in handle:lines() do
    lineNumber = lineNumber + 1
    if lineNumber > 1 and line ~= "" then
      local fields = splitTabSeparated(line)
      assertEqual(#fields, 3, "fixture row must have 3 columns at line " .. lineNumber)
      rows[#rows + 1] = { key = fields[1], decodedApp = fields[2], encodedApp = fields[3] }
    end
  end
  handle:close()
  assertEqual(#rows, 18, "fixture app count")
  return rows
end

local function sortedCopy(values)
  local copy = {}
  for index, value in ipairs(values) do copy[index] = value end
  table.sort(copy)
  return copy
end

local function exportedAllowlist(module)
  assert(type(module.allowedApps) == "table", "app_launcher must expose allowedApps")
  return sortedCopy(module.allowedApps)
end

local fixtureApps = loadFixtureApps()
local expectedApps = {}
for _, row in ipairs(fixtureApps) do expectedApps[#expectedApps + 1] = row.decodedApp end

local function resetObservedState()
  for key in pairs(launchCalls) do launchCalls[key] = nil end
  for key in pairs(hudEvents) do hudEvents[key] = nil end
  for key in pairs(alertCalls) do alertCalls[key] = nil end
  for key in pairs(launchResults) do launchResults[key] = nil end
end

_G.hs = {
  hotkey = {
    bind = function()
      error("app_launcher must not register hotkeys directly")
    end,
  },
  urlevent = {
    bind = function() error("app_launcher must not use hs.urlevent") end,
  },
  application = {
    launchOrFocus = function(app)
      launchCalls[#launchCalls + 1] = app
      hudEvents[#hudEvents + 1] = "launch:" .. app
      if launchResults[app] == nil then return true end
      return launchResults[app]
    end,
  },
  alert = {
    show = function(message, seconds)
      alertCalls[#alertCalls + 1] = { message = message, seconds = seconds }
    end,
  },
}

package.path = "./?.lua;./tests/?.lua;" .. package.path
package.preload["components.hud"] = function()
  return {
    showTransient = function(message)
      hudEvents[#hudEvents + 1] = "show:" .. message
      return {}
    end,
    closeTransient = function()
      hudEvents[#hudEvents + 1] = "close"
    end,
  }
end

local loaded, appLauncher = pcall(require, "actions.app_launcher")
assert(loaded, "expected app_launcher.lua to be require-able")
assert(type(appLauncher) == "table", "app_launcher must return a module table")
assert(type(appLauncher.launch) == "function", "app_launcher.launch() must be exported")
assertTableEqual(exportedAllowlist(appLauncher), sortedCopy(expectedApps), "explicit allowlist must match fixture apps")

for _, row in ipairs(fixtureApps) do
  assertEqual(appLauncher.keyToApp[row.key], row.decodedApp, "key/app mapping for " .. row.key)
end

for _, row in ipairs(fixtureApps) do
  local app = row.decodedApp
  resetObservedState()
  appLauncher.launch(app)
  assertTableEqual(launchCalls, { app }, "launch calls for " .. app)
  assertTableEqual(hudEvents, {
    "show:Launching " .. app .. "...",
    "launch:" .. app,
    "close",
  }, "HUD and launch sequence for " .. app)
  assertEqual(#alertCalls, 0, "successful launch should not notify failure for " .. app)
end

resetObservedState()
launchResults["Arc"] = false
appLauncher.launch("Arc")
assertTableEqual(launchCalls, { "Arc" }, "failed launch still attempts launchOrFocus once")
assertTableEqual(hudEvents, {
  "show:Launching Arc...",
  "launch:Arc",
  "close",
}, "failed launch still closes HUD after launch attempt")
assertEqual(#alertCalls, 1, "failed launch should show one alert")
assertEqual(alertCalls[1].message, "コマンドを実行できませんでした。", "failed launch alert format")
assertEqual(alertCalls[1].seconds, 2, "failed launch alert duration")

local rejectedApps = {
  { name = "allowlist外アプリ", app = "Unapproved App" },
  { name = "空文字列", app = "" },
  { name = "nil", app = nil },
}
for _, testCase in ipairs(rejectedApps) do
  resetObservedState()
  appLauncher.launch(testCase.app)
  assertEqual(#launchCalls, 0, "rejected " .. testCase.name .. " must not call launchOrFocus")
  assertEqual(#hudEvents, 0, "rejected " .. testCase.name .. " must not change HUD")
  assertEqual(#alertCalls, 0, "rejected " .. testCase.name .. " must not show an alert")
end

resetObservedState()
appLauncher.launch("Slack")
assertTableEqual(launchCalls, { "Slack" }, "action remains usable after a prior launch")

print("app_launcher_test: ok")
