local alerts = {}
local timers = {}
local tasks = {}
local taskCallbacks = {}
local taskID = 0
local hudEvents = {}
local resultShown = false
local httpRequests = {}
local clipboard = "prior clipboard"
local clipboardCount = 1
local pasteCalls = 0
local frontmostTarget = {}
local replaceFailure = nil
local appLookupFailure = nil

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
      error("stub replaced below")
    end,
  },
  json = {
    encode = function(payload)
      local prompt = payload.contents[1].parts[1].text
      return "PROMPT:" .. prompt
    end,
    decode = function() return { candidates = { { content = { parts = { { text = "結果" } } } } } } end,
  },
  uielement = {
    focusedElement = function()
      return { selectedText = function() return "入力" end }
    end,
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
  pasteboard = {
    getContents = function() return clipboard end,
    changeCount = function() return clipboardCount end,
    setContents = function(value) clipboard = value; clipboardCount = clipboardCount + 1; return true end,
    clearContents = function() clipboard = nil; clipboardCount = clipboardCount + 1; return true end,
  },
  eventtap = {
    keyStroke = function(modifiers, key)
      assertEqual(table.concat(modifiers, "+"), "cmd", "replace uses Command-V")
      assertEqual(key, "v", "replace uses Command-V")
      if replaceFailure == "keyStroke" then error("injected Command-V failure") end
      pasteCalls = pasteCalls + 1
      return true
    end,
  },
  application = {
    frontmostApplication = function()
      if appLookupFailure then error("injected frontmost application failure") end
      return frontmostTarget
    end,
  },
}

_G.hs.http.asyncPost = function(url, body, headers, callback)
  httpRequests[#httpRequests + 1] = { url = url, body = body, headers = headers }
  tasks.httpCallback = callback
end
frontmostTarget.isFrontmost = function()
  if replaceFailure == "isFrontmost" then error("injected isFrontmost failure") end
  return true
end
frontmostTarget.activate = function()
  if replaceFailure == "activate" then error("injected activate failure") end
  return true
end

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
local promptPath = "./tests/fixtures/ai_prompt.md"
local missingPromptPath = "./tests/fixtures/missing-ai-prompt.md"
local model = "test-model"

local function requestCount() return #httpRequests end

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

local function startCommand(failureStage, requestedOutput)
  local firstTaskID = taskID + 1
  ai.run(promptPath, model, requestedOutput or "display")
  assertEqual(taskID, firstTaskID, "AI start creates account task")
  if failureStage == "account" then return firstTaskID end
  completeTask(firstTaskID, 0, "test-account\n")
  assertEqual(taskID, firstTaskID + 1, "account success creates keychain task")
  if failureStage == "keychain" then return firstTaskID + 1 end
  completeTask(firstTaskID + 1, 0, "test-api-key\n")
  assert(tasks.httpCallback, "keychain success starts API request")
end

local function assertMissingPromptDoesNotStart()
  local beforeTaskID = taskID
  ai.run(missingPromptPath, model, "display")
  assertEqual(taskID, beforeTaskID, "missing prompt does not start a task")
end

local function assertWaitingHUD(eventIndexValue, message)
  local event = hudEvents[eventIndexValue]
  assert(type(event) == "string" and event:match("^show:.+"), message)
end

assertMissingPromptDoesNotStart()
startCommand()
assertWaitingHUD(1, "AI start shows a waiting HUD with a message")
assertEqual(requestCount(), 1, "AI starts one HTTP request")
assertEqual(httpRequests[1].url,
  "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent",
  "AI request URL uses the supplied model")
assertEqual(httpRequests[1].body, "PROMPT:AI prompt: 入力", "AI request body uses the supplied prompt contents")
assertEqual(httpRequests[1].headers["Content-Type"], "application/json", "AI request content type")
assertEqual(httpRequests[1].headers["x-goog-api-key"], "test-api-key", "AI request API key header")
tasks.httpCallback(200, "{}", "")
assertEqual(eventIndex("close") < eventIndex("result"), true, "success closes HUD before result display")
assertEqual(pasteCalls, 0, "display mode does not paste")
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

local priorClipboard = clipboard
local priorPasteCalls = pasteCalls
startCommand(nil, "replace")
tasks.httpCallback(200, "{}", "")
assertEqual(pasteCalls, priorPasteCalls + 1, "replace mode pastes the response into the target")
assertEqual(clipboard, "結果", "replace mode places the response on the clipboard before paste")
fireLatestTimer()
assertEqual(clipboard, priorClipboard, "replace mode restores the prior clipboard")
assertEqual(liveTimers(), 0, "replace mode leaves no timers after restore")

local function resetReplaceState()
  replaceFailure = nil
  appLookupFailure = nil
  clipboard = "prior clipboard"
  clipboardCount = 1
  pasteCalls = 0
  tasks.httpCallback = nil
end

local function runReplaceFailure(label, failure)
  resetReplaceState()
  replaceFailure = failure
  if failure == "frontmost" then appLookupFailure = true end
  local priorAlerts, priorCloses = #alerts, eventCount("close")
  local priorTasks = taskID
  ai.run(promptPath, model, "replace")
  local started = taskID ~= priorTasks
  if started then
    completeTask(taskID, 0, "test-account\n")
    completeTask(taskID, 0, "test-api-key\n")
    assert(tasks.httpCallback, label .. " starts its HTTP request")
    tasks.httpCallback(200, "{}", "")
  end
  while liveTimers() > 0 do fireLatestTimer() end
  assertEqual(#alerts, priorAlerts + 1, label .. " shows one replace failure notification")
  assertEqual(liveTimers(), 0, label .. " leaves no timers")
  assertEqual(eventCount("close"), priorCloses + (started and 1 or 0), label .. " cleans up the HUD")
  assertEqual(clipboard, "prior clipboard", label .. " leaves the prior clipboard unchanged or restored")
  assertEqual(pasteCalls, 0, label .. " does not complete a paste")
  replaceFailure = nil
  appLookupFailure = nil
end

runReplaceFailure("Command-V failure", "keyStroke")
runReplaceFailure("activate failure", "activate")
runReplaceFailure("isFrontmost failure", "isFrontmost")
runReplaceFailure("frontmost application failure", "frontmost")

local function assertInvalidInput(label, invalidPrompt, invalidModel, invalidMode)
  local beforeTasks, beforeRequests = taskID, requestCount()
  ai.run(invalidPrompt, invalidModel, invalidMode)
  assertEqual(taskID, beforeTasks, label .. " does not start a task")
  assertEqual(requestCount(), beforeRequests, label .. " does not start HTTP")
end

for _, testCase in ipairs({
  { label = "nil model", model = nil },
  { label = "empty model", model = "" },
  { label = "non-string model", model = 42 },
}) do
  assertInvalidInput(testCase.label, promptPath, testCase.model, "display")
end
for _, testCase in ipairs({
  { label = "nil mode", mode = nil },
  { label = "invalid mode", mode = "invalid" },
  { label = "non-string mode", mode = 42 },
}) do
  assertInvalidInput(testCase.label, promptPath, model, testCase.mode)
end
for _, testCase in ipairs({
  { label = "nil prompt", prompt = nil },
  { label = "empty prompt", prompt = "" },
  { label = "non-string prompt", prompt = 42 },
}) do
  assertInvalidInput(testCase.label, testCase.prompt, model, "display")
end

print("ai_command_hud_test: ok")
