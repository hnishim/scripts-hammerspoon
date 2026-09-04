local alerts = {}
local timers = {}
local tasks = {}
local taskCallbacks = {}
local taskID = 0
local hudEvents = {}
local httpRequests = {}
local decodeQueue = {}
local clipboard = "prior clipboard"
local clipboardCount = 1
local clipboardItems = { ["public.utf8-plain-text"] = "prior clipboard" }
local clipboardContentTypes = { { "public.utf8-plain-text" } }
local clipboardFailure = nil
local pasteCalls = 0
local copyCalls = 0
local clearCalls = 0
local writeAllDataCalls = 0
local frontmostTarget = {}
local frontmostIsPowerPoint = false
local frontmostPowerPointBundleID = "com.microsoft.Powerpoint"
local focusedSelection = "入力"
local copyResult = "入力"
local copyContentType = "public.utf8-plain-text"
local copyFailure = nil
local dialogResult = { "実行", "手入力" }
local dialogCalls = {}
local replaceFailure = nil
local appLookupFailure = nil
local frontmostLostAfterCopy = false
local frontmostActuallyLost = false

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
  dialog = {
    textPrompt = function(...)
      dialogCalls[#dialogCalls + 1] = { ... }
      return dialogResult[1], dialogResult[2]
    end,
  },
  json = {
    encode = function(payload)
      local prompt = payload.contents[1].parts[1].text
      return "PROMPT:" .. prompt
    end,
    decode = function()
      local nextResult = table.remove(decodeQueue, 1)
      if nextResult == "error" then error("injected JSON decode failure") end
      if nextResult ~= nil then return nextResult end
      return { candidates = { { content = { parts = { { text = "結果" } } } } } }
    end,
  },
  uielement = {
    focusedElement = function()
      return { selectedText = function()
        if focusedSelection == "error" then error("injected selectedText failure") end
        return focusedSelection
      end }
    end,
  },
  drawing = { windowLevels = { floating = 1 } },
  screen = { mainScreen = function() return { frame = function() return { x = 0, y = 0, w = 1200, h = 800 } end } end },
  pasteboard = {
    getContents = function() return clipboard end,
    changeCount = function() return clipboardCount end,
    allContentTypes = function()
      if clipboardFailure == "allContentTypes" then error("injected allContentTypes failure") end
      local types = {}
      for index, itemTypes in ipairs(clipboardContentTypes) do
        types[index] = {}
        for utiIndex, uti in ipairs(itemTypes) do types[index][utiIndex] = uti end
      end
      return types
    end,
    readAllData = function()
      if clipboardFailure == "readAllData" then error("injected readAllData failure") end
      local copy = {}
      for uti, data in pairs(clipboardItems) do copy[uti] = data end
      return copy
    end,
    writeAllData = function(data)
      if clipboardFailure == "writeAllData" then error("injected writeAllData failure") end
      clipboardItems = {}
      for uti, value in pairs(data) do clipboardItems[uti] = value end
      clipboard = clipboardItems["public.utf8-plain-text"] or clipboardItems["public.utf16-external-plain-text"]
      clipboardContentTypes = { { "public.utf8-plain-text" } }
      clipboardCount = clipboardCount + 1
      writeAllDataCalls = writeAllDataCalls + 1
      return true
    end,
    setContents = function(value)
      clipboard = value
      clipboardItems = { ["public.utf8-plain-text"] = value }
      clipboardContentTypes = { { "public.utf8-plain-text" } }
      clipboardCount = clipboardCount + 1
      return true
    end,
    clearContents = function()
      if clipboardFailure == "clearContents" then error("injected clearContents failure") end
      clipboard = nil
      clipboardItems = {}
      clipboardContentTypes = {}
      clipboardCount = clipboardCount + 1
      clearCalls = clearCalls + 1
      return true
    end,
  },
  eventtap = {
    keyStroke = function(modifiers, key)
      assertEqual(table.concat(modifiers, "+"), "cmd", "AI command uses Command key")
      if key == "c" then
        if copyFailure == "keyStroke" then error("injected Command-C failure") end
        copyCalls = copyCalls + 1
        if copyFailure ~= "noChange" then
          clipboard = copyResult
          clipboardItems = { [copyContentType] = copyResult }
          clipboardContentTypes = { { copyContentType } }
          clipboardCount = clipboardCount + 1
          if frontmostLostAfterCopy then frontmostActuallyLost = true end
        end
        return true
      end
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
  httpRequests[#httpRequests + 1] = { url = url, body = body, headers = headers, callback = callback }
  tasks.httpCallback = callback
end
frontmostTarget.isFrontmost = function()
  if replaceFailure == "isFrontmost" then error("injected isFrontmost failure") end
  if frontmostActuallyLost then return false end
  return true
end
frontmostTarget.bundleID = function()
  return frontmostIsPowerPoint and frontmostPowerPointBundleID or "com.example.Editor"
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
local resultPanelCalls = { show = {}, stop = 0 }
package.preload["components.result_panel"] = function()
  return {
    show = function(content) resultPanelCalls.show[#resultPanelCalls.show + 1] = content; hudEvents[#hudEvents + 1] = "result"; return true end,
    close = function() end,
    stop = function() resultPanelCalls.stop = resultPanelCalls.stop + 1; return true end,
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
  return requestCount()
end

local function responsePayload(text)
  return { candidates = { { content = { parts = { { text = text } } } } } }
end

local failoverModel = "test-failover-model"
local function startFailoverCommand(requestedOutput)
  local firstTaskID = taskID + 1
  ai.run(promptPath, model, requestedOutput or "display", failoverModel)
  assertEqual(taskID, firstTaskID, "failover command creates account task")
  completeTask(firstTaskID, 0, "test-account\n")
  completeTask(firstTaskID + 1, 0, "test-api-key\n")
  assert(tasks.httpCallback, "failover command starts HTTP request")
  return requestCount()
end

local function completeHTTP(index, status, body)
  local request = httpRequests[index]
  assert(request and request.callback, "HTTP request " .. tostring(index) .. " has a callback")
  request.callback(status, body or "{}", "")
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
assertEqual(#resultPanelCalls.show, 1, "success delegates result display to result panel")
assertEqual(resultPanelCalls.show[1], "結果", "result panel receives the response text")
assertEqual(pasteCalls, 0, "display mode does not paste")
assertEqual(liveTimers(), 0, "success leaves no timers")

decodeQueue[#decodeQueue + 1] = responsePayload("一次成功結果")
local primarySuccessBeforeRequests = requestCount()
local primarySuccessBeforeShows = #resultPanelCalls.show
local primarySuccessBeforeCloses = eventCount("close")
local primarySuccess = startFailoverCommand()
completeHTTP(primarySuccess, 200, "primary-success-body")
assertEqual(requestCount(), primarySuccessBeforeRequests + 1,
  "configured failover primary success sends exactly one HTTP request")
assertEqual(#resultPanelCalls.show, primarySuccessBeforeShows + 1,
  "configured failover primary success displays exactly one result")
assertEqual(resultPanelCalls.show[#resultPanelCalls.show], "一次成功結果",
  "configured failover primary success displays the primary result")
assertEqual(eventCount("close"), primarySuccessBeforeCloses + 1,
  "configured failover primary success closes the HUD")
assertEqual(liveTimers(), 0, "configured failover primary success leaves no timers")

-- HIR-132: a configured failover retries the same rendered request once for
-- each request-level failure, while stale primary callbacks are ignored.
local function assertFailover(label, completePrimary, completeFallback)
  local beforeRequestCount = requestCount()
  local firstRequest = startFailoverCommand()
  assertEqual(firstRequest, beforeRequestCount + 1, label .. " starts one primary request")
  local primary = httpRequests[firstRequest]
  completePrimary(firstRequest)
  assertEqual(requestCount(), firstRequest + 1, label .. " starts exactly one fallback request")
  local fallback = httpRequests[firstRequest + 1]
  assertEqual(fallback.url,
    "https://generativelanguage.googleapis.com/v1beta/models/" .. failoverModel .. ":generateContent",
    label .. " uses the fallback model")
  assertEqual(fallback.body, primary.body, label .. " reuses the rendered prompt payload")
  completeFallback(firstRequest + 1)
  return primary, fallback
end

decodeQueue[#decodeQueue + 1] = responsePayload("フォールバック結果")
assertFailover("HTTP failure",
  function(index) completeHTTP(index, 503, "failure") end,
  function(index) completeHTTP(index, 200, "{}") end)
assertEqual(resultPanelCalls.show[#resultPanelCalls.show], "フォールバック結果", "HTTP failure fallback displays its result")

decodeQueue[#decodeQueue + 1] = "error"
assertFailover("decode failure",
  function(index) completeHTTP(index, 200, "not-json") end,
  function(index) completeHTTP(index, 200, "{}") end)

decodeQueue[#decodeQueue + 1] = { candidates = {} }
assertFailover("invalid response",
  function(index) completeHTTP(index, 200, "{}") end,
  function(index) completeHTTP(index, 200, "{}") end)

local timeoutPrimary, timeoutFallback = nil, nil
local beforeTimeoutFailover = requestCount()
local timeoutShowsBefore = #resultPanelCalls.show
timeoutPrimary = startFailoverCommand()
fireLatestTimer()
assertEqual(requestCount(), beforeTimeoutFailover + 2, "timeout starts exactly one fallback request")
timeoutFallback = httpRequests[timeoutPrimary + 1]
assertEqual(timeoutFallback.url,
  "https://generativelanguage.googleapis.com/v1beta/models/" .. failoverModel .. ":generateContent",
  "timeout fallback uses the fallback model")
assertEqual(timeoutFallback.body, httpRequests[timeoutPrimary].body, "timeout fallback reuses the rendered prompt payload")
decodeQueue[#decodeQueue + 1] = responsePayload("timeout fallback result")
completeHTTP(timeoutPrimary + 1, 200, "fallback-body")
assertEqual(#resultPanelCalls.show, timeoutShowsBefore + 1,
  "timeout fallback displays exactly one result")
assertEqual(resultPanelCalls.show[#resultPanelCalls.show], "timeout fallback result",
  "timeout fallback displays the fallback result")
local closesBeforeStalePrimary = eventCount("close")
local showsBeforeStalePrimary = #resultPanelCalls.show
local resultBeforeStalePrimary = resultPanelCalls.show[#resultPanelCalls.show]
completeHTTP(timeoutPrimary, 200, "stale primary body")
assertEqual(eventCount("close"), closesBeforeStalePrimary, "stale primary callback cannot close fallback result")
assertEqual(#resultPanelCalls.show, showsBeforeStalePrimary,
  "stale primary callback cannot display another result")
assertEqual(resultPanelCalls.show[#resultPanelCalls.show], resultBeforeStalePrimary,
  "stale primary callback cannot overwrite the fallback result")
assertEqual(liveTimers(), 0, "timeout fallback leaves no timers")

local alertsBeforeSecondFailure = #alerts
assertFailover("second failure",
  function(index) completeHTTP(index, 500, "failure") end,
  function(index) completeHTTP(index, 500, "failure") end)
assertEqual(#alerts, alertsBeforeSecondFailure + 1, "second failure uses the existing error notification")
assertEqual(liveTimers(), 0, "second failure leaves no timers")

local requestsBeforeNoFailover = requestCount()
local alertsBeforeNoFailover = #alerts
startCommand()
completeHTTP(requestsBeforeNoFailover + 1, 500, "failure")
assertEqual(requestCount(), requestsBeforeNoFailover + 1, "missing failover does not retry")
assertEqual(#alerts, alertsBeforeNoFailover + 1, "missing failover uses the existing error notification")
assertEqual(liveTimers(), 0, "missing failover leaves no timers")

local stopCallsBefore = resultPanelCalls.stop
assertEqual(ai.stop(), nil, "stop preserves the existing no-value API")
assertEqual(resultPanelCalls.stop, stopCallsBefore + 1, "stop delegates once to result panel")
assertEqual(resultPanelCalls.stop, 1, "first stop invokes result panel stop exactly once")

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
  clipboardItems = { ["public.utf8-plain-text"] = "prior clipboard" }
  clipboardContentTypes = { { "public.utf8-plain-text" } }
  clipboardFailure = nil
  copyResult = "入力"
  copyContentType = "public.utf8-plain-text"
  focusedSelection = "入力"
  frontmostIsPowerPoint = false
  frontmostPowerPointBundleID = "com.microsoft.Powerpoint"
  frontmostLostAfterCopy = false
  frontmostActuallyLost = false
  dialogResult = { "実行", "手入力" }
  dialogCalls = {}
  copyFailure = nil
  pasteCalls = 0
  copyCalls = 0
  clearCalls = 0
  writeAllDataCalls = 0
  tasks.httpCallback = nil
end

resetReplaceState()
local replaceFailoverBeforeCloses = eventCount("close")
local replaceFailoverBeforePasteCalls = pasteCalls
local replaceFailoverBeforeRequests = requestCount()
decodeQueue[#decodeQueue + 1] = responsePayload("フォールバック置換結果")
local replaceFailoverPrimary = startFailoverCommand("replace")
completeHTTP(replaceFailoverPrimary, 503, "replace primary failure")
local replaceFailoverFallback = replaceFailoverPrimary + 1
assertEqual(httpRequests[replaceFailoverFallback].url,
  "https://generativelanguage.googleapis.com/v1beta/models/test-failover-model:generateContent",
  "replace failover uses the fallback model")
assertEqual(httpRequests[replaceFailoverFallback].body, httpRequests[replaceFailoverPrimary].body,
  "replace failover reuses the rendered prompt payload")
completeHTTP(replaceFailoverFallback, 200, "replace fallback success")
assertEqual(pasteCalls, replaceFailoverBeforePasteCalls + 1,
  "replace failover pastes the fallback result into the target")
assertEqual(clipboard, "フォールバック置換結果",
  "replace failover pastes the fallback result")
fireLatestTimer()
assertEqual(clipboard, "prior clipboard", "replace failover restores the prior clipboard")
assertEqual(liveTimers(), 0, "replace failover leaves no timers")
assertEqual(eventCount("close"), replaceFailoverBeforeCloses + 1,
  "replace failover closes the HUD once")
assertEqual(requestCount(), replaceFailoverBeforeRequests + 2,
  "replace failover sends primary and fallback requests")

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

-- HIR-125: PowerPoint uses Accessibility selection first and Command-C only as a fallback.
local function completeSuccessfulRequest(mode)
  local firstTaskID = taskID + 1
  ai.run(promptPath, model, mode or "display")
  assertEqual(taskID, firstTaskID, "scenario creates account task")
  completeTask(firstTaskID, 0, "test-account\n")
  completeTask(firstTaskID + 1, 0, "test-api-key\n")
  assert(tasks.httpCallback, "scenario starts HTTP request")
  tasks.httpCallback(200, "{}", "")
end

local function completePowerPointReplaceFallback(label, selectionValue, copiedText, bundleID)
  resetReplaceState()
  frontmostIsPowerPoint = true
  if bundleID then frontmostPowerPointBundleID = bundleID end
  focusedSelection = selectionValue
  copyResult = copiedText
  clipboard = "置換前テキスト"
  clipboardItems = {
    ["public.utf8-plain-text"] = "置換前テキスト",
    ["public.rtf"] = "{\\rtf1 置換前テキスト}",
  }
  clipboardContentTypes = { { "public.utf8-plain-text", "public.rtf" } }
  local beforeTaskID = taskID
  local beforeRequestCount = requestCount()
  local beforeCopyCalls = copyCalls
  local beforePasteCalls = pasteCalls
  local beforeWriteCalls = writeAllDataCalls
  ai.run(promptPath, model, "replace")
  assertEqual(copyCalls, beforeCopyCalls + 1, label .. " invokes Command-C")
  fireLatestTimer()
  assertEqual(taskID, beforeTaskID + 1, label .. " starts Gemini account lookup")
  completeTask(beforeTaskID + 1, 0, "test-account\n")
  completeTask(beforeTaskID + 2, 0, "test-api-key\n")
  assert(tasks.httpCallback, label .. " starts HTTP")
  tasks.httpCallback(200, "{}", "")
  assertEqual(requestCount(), beforeRequestCount + 1, label .. " sends one Gemini request")
  assertEqual(httpRequests[#httpRequests].body, "PROMPT:AI prompt: " .. copiedText,
    label .. " includes copied text in the Gemini request body")
  assertEqual(pasteCalls, beforePasteCalls + 1, label .. " executes Command-V")
  fireLatestTimer()
  assertEqual(clipboard, "置換前テキスト", label .. " restores the original clipboard text")
  assertEqual(clipboardItems["public.rtf"], "{\\rtf1 置換前テキスト}",
    label .. " restores the original RTF data")
  assertEqual(writeAllDataCalls, beforeWriteCalls + 1, label .. " restores all UTI data")
end

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = "PowerPoint選択"
local copyCallsBeforeSelection = copyCalls
completeSuccessfulRequest()
assertEqual(copyCalls, copyCallsBeforeSelection, "PowerPoint selected text does not invoke Command-C")
assertEqual(httpRequests[#httpRequests].body, "PROMPT:AI prompt: PowerPoint選択",
  "PowerPoint selected text goes directly to Gemini")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = "応答待ち中の直接選択"
local tasksBeforeReplaceClipboardChange = taskID
local requestsBeforeReplaceClipboardChange = requestCount()
local alertsBeforeReplaceClipboardChange = #alerts
local pasteCallsBeforeReplaceClipboardChange = pasteCalls
ai.run(promptPath, model, "replace")
completeTask(tasksBeforeReplaceClipboardChange + 1, 0, "test-account\n")
completeTask(tasksBeforeReplaceClipboardChange + 2, 0, "test-api-key\n")
assertEqual(requestCount(), requestsBeforeReplaceClipboardChange + 1,
  "direct Accessibility replace starts the Gemini request")
hs.pasteboard.setContents("ユーザー変更")
tasks.httpCallback(200, "{}", "")
assertEqual(clipboard, "ユーザー変更", "replace does not overwrite a clipboard change during Gemini")
assertEqual(pasteCalls, pasteCallsBeforeReplaceClipboardChange,
  "replace does not execute Command-V after a clipboard conflict")
fireLatestTimer()
assertEqual(#alerts, alertsBeforeReplaceClipboardChange + 1,
  "replace clipboard conflict shows a safe error")

completePowerPointReplaceFallback("PowerPoint nil selection replace", nil, "replace Command-C選択")
completePowerPointReplaceFallback("PowerPoint selectedText exception replace", "error", "replace Accessibility例外後の選択")
completePowerPointReplaceFallback("legacy PowerPoint bundle ID replace", nil, "legacy Bundle ID選択", "com.microsoft.PowerPoint")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = nil
copyResult = "Command-C選択"
local tasksBeforeCopySuccess = taskID
ai.run(promptPath, model, "display")
assertEqual(copyCalls, 1, "PowerPoint nil selection invokes Command-C for fallback success")
fireLatestTimer()
assertEqual(taskID, tasksBeforeCopySuccess + 1, "copied PowerPoint selection starts the account lookup")
completeTask(tasksBeforeCopySuccess + 1, 0, "test-account\n")
completeTask(tasksBeforeCopySuccess + 2, 0, "test-api-key\n")
assert(tasks.httpCallback, "copied PowerPoint selection starts HTTP")
tasks.httpCallback(200, "{}", "")
assertEqual(httpRequests[#httpRequests].body, "PROMPT:AI prompt: Command-C選択",
  "Command-C selection is included in the Gemini prompt body")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = "error"
copyResult = "Accessibility例外後の選択"
local tasksBeforeAccessibilityFallback = taskID
ai.run(promptPath, model, "display")
assertEqual(copyCalls, 1, "PowerPoint selectedText exception invokes Command-C fallback")
fireLatestTimer()
assertEqual(taskID, tasksBeforeAccessibilityFallback + 1, "Accessibility exception fallback starts the account lookup")
completeTask(tasksBeforeAccessibilityFallback + 1, 0, "test-account\n")
completeTask(tasksBeforeAccessibilityFallback + 2, 0, "test-api-key\n")
assert(tasks.httpCallback, "Accessibility exception fallback starts HTTP")
tasks.httpCallback(200, "{}", "")
assertEqual(httpRequests[#httpRequests].body, "PROMPT:AI prompt: Accessibility例外後の選択",
  "Accessibility exception fallback includes copied text in the Gemini prompt body")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = nil
copyResult = "前面喪失後の選択"
frontmostLostAfterCopy = true
local tasksBeforeLostFrontmost = taskID
local requestsBeforeLostFrontmost = requestCount()
local alertsBeforeLostFrontmost = #alerts
ai.run(promptPath, model, "replace")
fireLatestTimer()
assertEqual(taskID, tasksBeforeLostFrontmost, "PowerPoint losing frontmost status does not start Gemini task")
assertEqual(requestCount(), requestsBeforeLostFrontmost, "PowerPoint losing frontmost status does not start HTTP")
assertEqual(#alerts, alertsBeforeLostFrontmost + 1, "PowerPoint losing frontmost status shows a safe error")

for _, failure in ipairs({ "allContentTypes", "readAllData" }) do
  resetReplaceState()
  frontmostIsPowerPoint = true
  focusedSelection = nil
  copyResult = "退避失敗時の選択"
  clipboardFailure = failure
  local copyCallsBeforeFailure = copyCalls
  local tasksBeforeFailure = taskID
  local requestsBeforeFailure = requestCount()
  local alertsBeforeFailure = #alerts
  ai.run(promptPath, model, "replace")
  assertEqual(copyCalls, copyCallsBeforeFailure, failure .. " failure does not invoke Command-C")
  assertEqual(taskID, tasksBeforeFailure, failure .. " failure does not start Gemini task")
  assertEqual(requestCount(), requestsBeforeFailure, failure .. " failure does not start HTTP")
  assertEqual(#alerts, alertsBeforeFailure + 1, failure .. " failure shows a safe error")
end

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = nil
copyResult = ""
dialogResult = { "キャンセル", "" }
local dialogsBeforeNoSelection = #dialogCalls
local alertsBeforeNoSelection = #alerts
ai.run(promptPath, model, "display")
assertEqual(copyCalls, 1, "PowerPoint missing selection invokes Command-C once")
fireLatestTimer()
assertEqual(#dialogCalls, dialogsBeforeNoSelection + 1, "empty copied selection opens the input dialog")
assertEqual(#alerts, alertsBeforeNoSelection, "empty copied selection is not a safe error")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = "PowerPoint置換"
clipboard = nil
clipboardItems = {}
clipboardContentTypes = {}
local clearBeforeEmptyRestore = clearCalls
completeSuccessfulRequest("replace")
fireLatestTimer()
assertEqual(clearCalls, clearBeforeEmptyRestore + 1, "empty clipboard snapshot restores with clearContents")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = "全UTI置換"
clipboard = "元テキスト"
clipboardItems = {
  ["public.utf8-plain-text"] = "元テキスト",
  ["public.rtf"] = "{\\rtf1 元テキスト}",
}
clipboardContentTypes = { { "public.utf8-plain-text", "public.rtf" } }
local writesBeforeAllUTI = writeAllDataCalls
completeSuccessfulRequest("replace")
fireLatestTimer()
assertEqual(writeAllDataCalls, writesBeforeAllUTI + 1, "one clipboard item restores all UTI data")
assertEqual(clipboardItems["public.rtf"], "{\\rtf1 元テキスト}", "one-item restore preserves the RTF UTI")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = nil
clipboardItems = {
  ["public.utf8-plain-text"] = "既存テキスト",
  ["public.html"] = "<p>既存テキスト</p>",
}
clipboardContentTypes = { { "public.utf8-plain-text" }, { "public.html" } }
local tasksBeforeMultiple = taskID
local alertsBeforeMultiple = #alerts
ai.run(promptPath, model, "replace")
assertEqual(taskID, tasksBeforeMultiple, "multiple clipboard items do not start Gemini")
assertEqual(copyCalls, 0, "multiple clipboard items do not invoke Command-C")
assertEqual(#alerts, alertsBeforeMultiple + 1, "multiple clipboard items show a safe error")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = nil
copyContentType = "public.png"
copyResult = "PNG data"
local tasksBeforeNonText = taskID
local alertsBeforeNonText = #alerts
ai.run(promptPath, model, "display")
fireLatestTimer()
assertEqual(taskID, tasksBeforeNonText, "non-text clipboard selection does not start Gemini")
assertEqual(#alerts, alertsBeforeNonText + 1, "non-text clipboard selection shows a safe error")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = nil
copyContentType = "public.rtf"
copyResult = "{\\rtf1 styled selection}"
local tasksBeforeStyledText = taskID
ai.run(promptPath, model, "display")
fireLatestTimer()
assertEqual(taskID, tasksBeforeStyledText + 1, "styledText clipboard selection proceeds to Gemini")
completeTask(tasksBeforeStyledText + 1, 0, "test-account\n")
completeTask(tasksBeforeStyledText + 2, 0, "test-api-key\n")
tasks.httpCallback(200, "{}", "")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = nil
copyFailure = "noChange"
dialogResult = { "キャンセル", "" }
local dialogsBeforeCopyTimeout = #dialogCalls
ai.run(promptPath, model, "display")
fireLatestTimer()
assertEqual(#dialogCalls, dialogsBeforeCopyTimeout + 1, "unchanged clipboard after Command-C falls back to the input dialog")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = "復元競合"
completeSuccessfulRequest("replace")
hs.pasteboard.setContents("外部変更")
fireLatestTimer()
assertEqual(clipboard, "外部変更", "clipboard conflict prevents restoring over newer contents")
assertEqual(pasteCalls, 1, "clipboard conflict after paste does not undo the completed paste")

resetReplaceState()
frontmostIsPowerPoint = true
focusedSelection = "復元失敗"
clipboardFailure = "writeAllData"
local alertsBeforeRestoreFailure = #alerts
completeSuccessfulRequest("replace")
fireLatestTimer()
assertEqual(#alerts, alertsBeforeRestoreFailure + 1, "clipboard restore failure shows a safe error")

resetReplaceState()
frontmostIsPowerPoint = false
focusedSelection = "通常アプリ選択"
local copyCallsBeforeNonPowerPoint = copyCalls
completeSuccessfulRequest()
assertEqual(copyCalls, copyCallsBeforeNonPowerPoint, "non-PowerPoint Accessibility path remains unchanged")
assertEqual(httpRequests[#httpRequests].body, "PROMPT:AI prompt: 通常アプリ選択",
  "non-PowerPoint selected text is sent through the existing path")

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
