local alerts = {}
local timers = {}
local tasks = {}
local taskCallbacks = {}
local taskID = 0
local hudEvents = {}
local resultShown = false

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function addTimer(delay, callback)
  local timer = { delay = delay, callback = callback, stopped = false }
  function timer:stop() self.stopped = true end
  timers[#timers + 1] = timer
  return timer
end

local function liveTimers()
  local count = 0
  for _, timer in ipairs(timers) do
    if not timer.stopped then count = count + 1 end
  end
  return count
end

local function completeTask(id, exitCode, stdout, stderr)
  assert(taskCallbacks[id], "missing task callback " .. tostring(id))
  taskCallbacks[id](exitCode, stdout or "", stderr or "")
end

local function fireLatestTimer()
  for index = #timers, 1, -1 do
    local timer = timers[index]
    if not timer.stopped then
      timer.stopped = true
      timer.callback()
      return timer
    end
  end
  error("missing live timer")
end

_G.hs = {
  alert = { show = function(message) alerts[#alerts + 1] = message end },
  timer = { doAfter = addTimer, stop = function(timer) timer:stop() end },
  task = {
    new = function(_, callback)
      taskID = taskID + 1
      taskCallbacks[taskID] = callback
      local task = { terminate = function() end }
      tasks[taskID] = task
      function task:start() return true end
      return task
    end,
  },
  http = {
    asyncPost = function(_, _, _, callback)
      tasks.httpCallback = callback
    end,
  },
  json = {
    encode = function() return "{}" end,
    decode = function() return { candidates = { { content = { parts = { { text = "結果" } } } } } } end,
  },
  drawing = { windowLevels = { floating = 1 } },
  screen = { mainScreen = function() return { frame = function() return { x = 0, y = 0, w = 1200, h = 800 } end } end },
  webview = { new = function()
    local view = {}
    local function chain() return view end
    view.windowStyle, view.windowTitle, view.level, view.allowGestures = chain, chain, chain, chain
    view.allowTextEntry, view.closeOnEscape, view.shadow, view.windowCallback = chain, chain, chain, chain
    view.html = function() return view end
    view.show = function() resultShown = true; hudEvents[#hudEvents + 1] = "result"; return view end
    view.delete = function() end
    return view
  end },
}

package.path = "./?.lua;" .. package.path
package.preload["components.hud"] = function()
  return {
    show = function(message)
      hudEvents[#hudEvents + 1] = "show:" .. message
    end,
    close = function()
      hudEvents[#hudEvents + 1] = "close"
    end,
  }
end

local ai = require("actions.ai_commands")
local command = { prompt = "./tests/fixtures/ai_prompt.md", model = "test-model" }

local function eventIndex(value)
  for index, event in ipairs(hudEvents) do
    if event == value then return index end
  end
  return nil
end

local function eventCount(value)
  local count = 0
  for _, event in ipairs(hudEvents) do
    if event == value then count = count + 1 end
  end
  return count
end

local function startCommand(failureStage)
  local firstTaskID = taskID + 1
  ai.run(command, "入力", "display", nil)
  assertEqual(taskID, firstTaskID, "AI start creates account task")
  if failureStage == "account" then return firstTaskID end
  completeTask(firstTaskID, 0, "test-account\n")
  assertEqual(taskID, firstTaskID + 1, "account success creates keychain task")
  if failureStage == "keychain" then return firstTaskID + 1 end
  completeTask(firstTaskID + 1, 0, "test-api-key\n")
  assert(tasks.httpCallback, "keychain success starts API request")
end

local function assertWaitingHUD(eventIndexValue, message)
  local event = hudEvents[eventIndexValue]
  assert(type(event) == "string" and event:match("^show:.+"), message)
end

startCommand()
assertWaitingHUD(1, "AI start shows a waiting HUD with a message")
tasks.httpCallback(200, "{}", "")
assertEqual(eventIndex("close") < eventIndex("result"), true, "success closes HUD before result display")
assertEqual(liveTimers(), 0, "success leaves no timers")

local eventsBeforeFailure = #hudEvents
local alertsBeforeAccountFailure = #alerts
local accountTaskID = startCommand("account")
completeTask(accountTaskID, 1, "", "account failure")
assertWaitingHUD(eventsBeforeFailure + 1, "account failure path shows a waiting HUD with a message")
assertEqual(hudEvents[#hudEvents], "close", "account failure closes waiting HUD")
assertEqual(#alerts, alertsBeforeAccountFailure + 1, "account failure shows the existing error notification")
assertEqual(liveTimers(), 0, "account failure leaves no timers")

local eventsBeforeKeychainFailure = #hudEvents
local alertsBeforeKeychainFailure = #alerts
local keychainTaskID = startCommand("keychain")
completeTask(keychainTaskID, 1, "", "keychain failure")
assertWaitingHUD(eventsBeforeKeychainFailure + 1, "keychain failure path shows a waiting HUD with a message")
assertEqual(hudEvents[#hudEvents], "close", "keychain failure closes waiting HUD")
assertEqual(#alerts, alertsBeforeKeychainFailure + 1, "keychain failure shows the existing error notification")
assertEqual(liveTimers(), 0, "keychain failure leaves no timers")

local alertsBeforeAPIFailure = #alerts
startCommand()
tasks.httpCallback(500, "failure", "")
assertEqual(hudEvents[#hudEvents], "close", "API failure closes waiting HUD")
assertEqual(#alerts, alertsBeforeAPIFailure + 1, "API failure shows the existing error notification")
assertEqual(liveTimers(), 0, "API failure leaves no timers")

local alertsBeforeTimeout = #alerts
startCommand()
fireLatestTimer()
assertEqual(hudEvents[#hudEvents], "close", "timeout closes waiting HUD")
assertEqual(#alerts, alertsBeforeTimeout + 1, "timeout shows the existing error notification")
assertEqual(liveTimers(), 0, "timeout leaves no timers")

local closesBeforeDuplicate = eventCount("close")
tasks.httpCallback(500, "failure", "")
assertEqual(eventCount("close"), closesBeforeDuplicate, "duplicate completion does not close again")
assertEqual(#alerts, alertsBeforeTimeout + 1, "duplicate completion does not show another alert")

local eventsBeforeTimeoutRetry = #hudEvents
local alertsBeforeTimeoutRetry = #alerts
startCommand()
assertWaitingHUD(eventsBeforeTimeoutRetry + 1, "a timed-out command can be run again")
assertEqual(liveTimers(), 1, "retry owns one active API timer")
tasks.httpCallback(200, "{}", "")
assertEqual(liveTimers(), 0, "successful retry leaves no timers")
assertEqual(#alerts, alertsBeforeTimeoutRetry, "successful retry needs no error notification")

print("ai_command_hud_test: ok")
