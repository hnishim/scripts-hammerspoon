local tasks = {}
local timers = {}
local httpRequests = {}
local encodedPayloads = {}
local alerts = {}
local resultPanelShows = {}
local hudEvents = {}
local helperTaskCreationFailure = false
local helperTaskStartFailure = false

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTrue(value, message)
  assert(value == true, message)
end

local function containsValue(value, expected)
  if value == expected then return true end
  if type(value) ~= "table" then return false end
  for _, child in pairs(value) do
    if containsValue(child, expected) then return true end
  end
  return false
end

local function isReplacementHelperPath(path)
  return type(path) == "string" and path:match("replacement%-engine$") ~= nil
end

local function timerAfter(delay, callback)
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

local function newTask(path, callback, streamOrArguments, maybeArguments)
  if helperTaskCreationFailure and isReplacementHelperPath(path) then return nil end

  local streamCallback, arguments
  if type(streamOrArguments) == "function" then
    streamCallback = streamOrArguments
    arguments = maybeArguments
  else
    arguments = streamOrArguments
  end

  local task = {
    path = path,
    callback = callback,
    streamCallback = streamCallback,
    arguments = arguments or {},
    inputs = {},
    started = false,
    terminated = false,
    inputClosed = false,
  }
  function task:start()
    if helperTaskStartFailure and isReplacementHelperPath(self.path) then return false end
    self.started = true
    return self
  end
  function task:terminate() self.terminated = true; return self end
  function task:setInput(value) self.inputs[#self.inputs + 1] = value; return self end
  function task:closeInput() self.inputClosed = true; return self end
  function task:setStreamingCallback(fn) self.streamCallback = fn; return self end
  tasks[#tasks + 1] = task
  return task
end

local function completeTask(task, exitCode, stdout, stderr)
  assert(task and task.callback, "task callback is missing")
  task.callback(exitCode or 0, stdout or "", stderr or "")
end

local function streamTask(task, stdout, stderr)
  assert(task and task.streamCallback, "streaming callback is missing")
  return task.streamCallback(task, stdout or "", stderr or "")
end

local frontmost = {}
function frontmost:isFrontmost() return true end
function frontmost:activate() return true end
function frontmost:bundleID() return "com.example.Editor" end

_G.hs = {
  alert = { show = function(message) alerts[#alerts + 1] = message end },
  timer = { doAfter = timerAfter },
  task = { new = newTask },
  http = {
    asyncPost = function(url, body, headers, callback)
      httpRequests[#httpRequests + 1] = { url = url, body = body, headers = headers, callback = callback }
    end,
  },
  json = {
    encode = function(payload)
      encodedPayloads[#encodedPayloads + 1] = payload
      return "ENCODED:" .. tostring(#encodedPayloads)
    end,
    decode = function(value)
      if value:find("MALFORMED", 1, true) then error("injected malformed helper protocol") end
      if value:find('"event"%s*:%s*"capture"') then
        local eligible = value:find('"replacement_eligible"%s*:%s*false') == nil
        return {
          event = "capture",
          type = "capture",
          selection = "入力",
          selected_text = "入力",
          replacement_eligible = eligible,
          reason = eligible and "strong_identity" or "weak_identity",
        }
      end
      if value:find('"event"%s*:%s*"unknown"') then
        return { event = "unknown", type = "unknown", reason = "fixture_unknown_event" }
      end
      if value:find("replacement_dispatched_unverified", 1, true) then
        return {
          event = "outcome",
          type = "outcome",
          outcome = "replacement_dispatched_unverified",
          strategy = "clipboard_cmd_v",
          reason = "dispatched_unverified",
        }
      end
      if value:find('"outcome"%s*:%s*"not_replaced"') then
        return {
          event = "outcome",
          type = "outcome",
          outcome = "not_replaced",
          reason = "target_drift",
        }
      end
      if value:find('"outcome"%s*:%s*"error"') then
        return {
          event = "outcome",
          type = "outcome",
          outcome = "error",
          reason = "helper_error",
        }
      end
      return { candidates = { { content = { parts = { { text = "結果" } } } } } }
    end,
  },
  uielement = {
    focusedElement = function()
      return {
        selectedText = function() return "入力" end,
        attributeValue = function(_, name)
          if name == "AXRole" then return "AXTextField" end
          if name == "AXEditable" then return true end
          return nil
        end,
      }
    end,
  },
  application = { frontmostApplication = function() return frontmost end },
  pasteboard = {
    getContents = function() return "prior clipboard" end,
    changeCount = function() return 1 end,
    allContentTypes = function() return { { "public.utf8-plain-text" } } end,
    readAllData = function() return { ["public.utf8-plain-text"] = "prior clipboard" } end,
    writeAllData = function() return true end,
    setContents = function() return true end,
    clearContents = function() return true end,
  },
  eventtap = { keyStroke = function() return true end },
  dialog = { textPrompt = function() return "キャンセル", "" end },
}

package.path = "./?.lua;" .. package.path
package.preload["components.hud"] = function()
  return {
    show = function(message) hudEvents[#hudEvents + 1] = "show:" .. tostring(message) end,
    close = function() hudEvents[#hudEvents + 1] = "close" end,
  }
end
package.preload["components.result_panel"] = function()
  return {
    show = function(content) resultPanelShows[#resultPanelShows + 1] = content; return true end,
    close = function() return true end,
    stop = function() return true end,
  }
end

local ai = require("actions.ai_commands")
local promptPath = "./tests/fixtures/ai_prompt.md"
local model = "test-model"

local function taskAt(index, message)
  local task = tasks[index]
  assert(task, message or ("missing task " .. tostring(index)))
  return task
end

local function completeCredentials(firstIndex)
  local account = taskAt(firstIndex, "account task is missing")
  assertEqual(account.path, "/usr/bin/id", "account lookup task path")
  completeTask(account, 0, "test-account\n", "")
  local security = taskAt(firstIndex + 1, "keychain task is missing")
  assertEqual(security.path, "/usr/bin/security", "keychain task path")
  completeTask(security, 0, "test-api-key\n", "")
end

local function emitCapture(helper, eligible)
  local eligibleValue = eligible and "true" or "false"
  streamTask(helper,
    '{"event":"capture","selection":"入力","replacement_eligible":' .. eligibleValue .. ',"reason":"' ..
      (eligible and "strong_identity" or "weak_identity") .. '"}\n', "")
end

local function emitOutcome(helper, outcome)
  streamTask(helper, '{"event":"outcome","outcome":"' .. outcome .. '","reason":"fixture"}\n', "")
end

local function latestRequest()
  local request = httpRequests[#httpRequests]
  assert(request, "HTTP request is missing")
  return request
end

local function startReplaceWithoutCapture()
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  ai.run(promptPath, model, "replace")
  local helper = taskAt(beforeTasks + 1, "replace mode must start the replacement helper before Gemini")
  assertTrue(helper.started, "replacement helper is started")
  assertTrue(type(helper.streamCallback) == "function", "replacement helper uses a streaming callback")
  assertTrue(isReplacementHelperPath(helper.path), "replace mode starts replacement-engine before account/keychain lookup")
  for _, argument in ipairs(helper.arguments or {}) do
    assert(argument ~= "入力" and argument ~= "結果", "selection/replacement content is not passed as process arguments")
  end
  assertEqual(#httpRequests, beforeRequests, "Gemini does not start before helper capture")
  return helper, beforeTasks, beforeRequests
end

local function startEligibleReplace()
  local helper, beforeTasks, beforeRequests = startReplaceWithoutCapture()
  emitCapture(helper, true)
  completeCredentials(beforeTasks + 2)
  assertEqual(#httpRequests, beforeRequests + 1, "capture starts exactly one Gemini request")
  local foundPrompt = false
  for _, payload in ipairs(encodedPayloads) do
    if containsValue(payload, "AI prompt: 入力") then foundPrompt = true end
  end
  assertTrue(foundPrompt, "capture selection is rendered into the Gemini prompt")
  return helper, latestRequest()
end

-- Adjacent regression: display mode keeps the existing no-helper contract and passes before the HIR-235 fix.
do
  local beforeTasks = #tasks
  local beforePanels = #resultPanelShows
  ai.run(promptPath, model, "display")
  completeCredentials(beforeTasks + 1)
  latestRequest().callback(200, "GEMINI", "")
  assertEqual(#resultPanelShows, beforePanels + 1, "display mode shows the Gemini result")
  assertEqual(resultPanelShows[#resultPanelShows], "結果", "display mode result content")
end

-- Bug case: replace mode must hold one helper process across capture -> Gemini -> replacement outcome.
do
  local beforePanels = #resultPanelShows
  local beforeAlerts = #alerts
  local helper, request = startEligibleReplace()
  request.callback(200, "GEMINI", "")
  assertEqual(#helper.inputs, 1, "Gemini success sends exactly one replacement command to the held helper")
  local replacementWasEncoded = false
  for _, payload in ipairs(encodedPayloads) do
    if containsValue(payload, "結果") then replacementWasEncoded = true end
  end
  assertTrue(replacementWasEncoded, "replacement payload contains the Gemini response")
  assertEqual(#resultPanelShows, beforePanels, "no panel is shown before helper terminal outcome")
  emitOutcome(helper, "replacement_dispatched_unverified")
  completeTask(helper, 0, "", "")
  assertEqual(#resultPanelShows, beforePanels,
    "replacement_dispatched_unverified is terminal and does not show a duplicate result panel")
  assertEqual(#alerts, beforeAlerts, "replacement_dispatched_unverified is not treated as an error")
end

-- F1: weak identity can still supply Gemini input, but must never receive a replacement command.
do
  local beforePanels = #resultPanelShows
  local helper, beforeTasks, beforeRequests = startReplaceWithoutCapture()
  emitCapture(helper, false)
  completeCredentials(beforeTasks + 2)
  assertEqual(#httpRequests, beforeRequests + 1, "weak identity capture still starts Gemini for display-only output")
  local request = latestRequest()
  request.callback(200, "GEMINI", "")
  assertEqual(#helper.inputs, 0, "weak identity never receives a replacement payload")
  assertEqual(#resultPanelShows, beforePanels + 1, "weak identity displays the Gemini result exactly once")
  assertEqual(resultPanelShows[#resultPanelShows], "結果", "weak identity display-only result content")
end

-- Safe fallback: a certain no-mutation outcome may display the already-computed result once.
do
  local beforePanels = #resultPanelShows
  local helper, request = startEligibleReplace()
  request.callback(200, "GEMINI", "")
  emitOutcome(helper, "not_replaced")
  completeTask(helper, 0, "", "")
  assertEqual(#resultPanelShows, beforePanels + 1, "not_replaced falls back to the result panel once")
  assertEqual(resultPanelShows[#resultPanelShows], "結果", "not_replaced panel receives the Gemini result")
end

-- Error outcome must not also expose a duplicate result panel.
do
  local beforePanels = #resultPanelShows
  local beforeAlerts = #alerts
  local helper, request = startEligibleReplace()
  request.callback(200, "GEMINI", "")
  emitOutcome(helper, "error")
  completeTask(helper, 1, "", "fixture error")
  assertEqual(#resultPanelShows, beforePanels, "helper error does not show a duplicate result panel")
  assertEqual(#alerts, beforeAlerts + 1, "helper error shows one generic safe error")
end

-- F2: missing helper binary/task creation fails closed before Gemini.
do
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforePanels = #resultPanelShows
  local beforeAlerts = #alerts
  helperTaskCreationFailure = true
  ai.run(promptPath, model, "replace")
  helperTaskCreationFailure = false
  assertEqual(#tasks, beforeTasks, "helper task creation failure does not start credential tasks")
  assertEqual(#httpRequests, beforeRequests, "helper task creation failure does not start Gemini")
  assertEqual(#resultPanelShows, beforePanels, "helper task creation failure does not show a duplicate result panel")
  assertEqual(#alerts, beforeAlerts + 1, "helper task creation failure shows one generic safe error")
end

-- F2: helper start failure fails closed before Gemini and leaves no running helper.
do
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforePanels = #resultPanelShows
  local beforeAlerts = #alerts
  helperTaskStartFailure = true
  ai.run(promptPath, model, "replace")
  helperTaskStartFailure = false
  local helper = taskAt(beforeTasks + 1, "failed-start helper task is missing")
  assertTrue(isReplacementHelperPath(helper.path), "failed-start task is the replacement helper")
  assertEqual(helper.started, false, "failed-start helper never becomes running")
  assertEqual(#httpRequests, beforeRequests, "helper start failure does not start Gemini")
  assertEqual(#resultPanelShows, beforePanels, "helper start failure does not show a duplicate result panel")
  assertEqual(#alerts, beforeAlerts + 1, "helper start failure shows one generic safe error")
end

-- F2: nonzero helper exit before capture cannot start Gemini or mutate.
do
  local beforePanels = #resultPanelShows
  local beforeAlerts = #alerts
  local helper, _, beforeRequests = startReplaceWithoutCapture()
  completeTask(helper, 1, "", "permission denied")
  assertEqual(#httpRequests, beforeRequests, "pre-capture helper exit does not start Gemini")
  assertEqual(#helper.inputs, 0, "pre-capture helper exit cannot receive replacement input")
  assertEqual(#resultPanelShows, beforePanels, "pre-capture helper exit does not show a duplicate panel")
  assertEqual(#alerts, beforeAlerts + 1, "pre-capture helper exit shows one generic safe error")
end

-- F2: malformed helper protocol terminates the session without mutation or duplicate panel.
do
  local beforePanels = #resultPanelShows
  local beforeAlerts = #alerts
  local helper, _, beforeRequests = startReplaceWithoutCapture()
  streamTask(helper, "MALFORMED\n", "")
  assertTrue(helper.terminated, "malformed helper protocol terminates the helper")
  assertEqual(#httpRequests, beforeRequests, "malformed helper protocol does not start Gemini")
  assertEqual(#helper.inputs, 0, "malformed helper protocol cannot trigger replacement input")
  assertEqual(#resultPanelShows, beforePanels, "malformed helper protocol does not show a duplicate panel")
  assertEqual(#alerts, beforeAlerts + 1, "malformed helper protocol shows one generic safe error")
end

-- F2: unknown helper event is rejected as protocol failure.
do
  local beforePanels = #resultPanelShows
  local beforeAlerts = #alerts
  local helper, _, beforeRequests = startReplaceWithoutCapture()
  streamTask(helper, '{"event":"unknown","reason":"fixture"}\n', "")
  assertTrue(helper.terminated, "unknown helper event terminates the helper")
  assertEqual(#httpRequests, beforeRequests, "unknown helper event does not start Gemini")
  assertEqual(#helper.inputs, 0, "unknown helper event cannot trigger replacement input")
  assertEqual(#resultPanelShows, beforePanels, "unknown helper event does not show a duplicate panel")
  assertEqual(#alerts, beforeAlerts + 1, "unknown helper event shows one generic safe error")
end

-- F2: capture timeout terminates the helper; a later stale capture is ignored.
do
  local beforePanels = #resultPanelShows
  local beforeAlerts = #alerts
  local helper, _, beforeRequests = startReplaceWithoutCapture()
  assertTrue(liveTimers() > 0, "replacement capture arms a watchdog")
  fireLatestTimer()
  assertTrue(helper.terminated, "capture timeout terminates the helper")
  assertEqual(#httpRequests, beforeRequests, "capture timeout does not start Gemini")
  assertEqual(#resultPanelShows, beforePanels, "capture timeout does not show a duplicate result panel")
  assertEqual(#alerts, beforeAlerts + 1, "capture timeout shows one generic safe error")
  emitCapture(helper, true)
  assertEqual(#httpRequests, beforeRequests, "stale capture after timeout cannot start Gemini")
  assertEqual(#helper.inputs, 0, "stale capture after timeout cannot trigger mutation")
end

-- F2: explicit cancellation before capture terminates the helper and ignores later events.
do
  local helper, _, beforeRequests = startReplaceWithoutCapture()
  ai.stop()
  assertTrue(helper.terminated, "capture-stage cancellation terminates the helper")
  emitCapture(helper, true)
  assertEqual(#httpRequests, beforeRequests, "stale capture after cancellation cannot start Gemini")
  assertEqual(#helper.inputs, 0, "stale capture after cancellation cannot trigger mutation")
end

-- Cancellation after Gemini: a stale Gemini callback after stop cannot write to the old helper.
do
  local helper, request = startEligibleReplace()
  ai.stop()
  assertTrue(helper.terminated, "stop terminates the held replacement helper")
  local inputsBefore = #helper.inputs
  local panelsBefore = #resultPanelShows
  request.callback(200, "GEMINI", "")
  assertEqual(#helper.inputs, inputsBefore, "stale Gemini callback cannot send replacement input")
  assertEqual(#resultPanelShows, panelsBefore, "stale Gemini callback cannot display a result")
end

-- Starting a new operation must terminate a still-waiting helper from the prior operation.
do
  local beforeTasks = #tasks
  ai.run(promptPath, model, "replace")
  local helper = taskAt(beforeTasks + 1, "replacement helper is missing")
  assertTrue(isReplacementHelperPath(helper.path), "replacement helper path")
  ai.run(promptPath, model, "display")
  assertTrue(helper.terminated, "new operation terminates the previous replacement helper")
end

print("ai_command_replacement_session_test: ok")
