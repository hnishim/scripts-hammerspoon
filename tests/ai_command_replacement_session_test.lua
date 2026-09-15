local tasks = {}
local timers = {}
local httpRequests = {}
local encodedPayloads = {}
local alerts = {}
local resultPanelShows = {}
local hudEvents = {}

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

local function timerAfter(delay, callback)
  local timer = { delay = delay, callback = callback, stopped = false }
  function timer:stop() self.stopped = true end
  timers[#timers + 1] = timer
  return timer
end

local function newTask(path, callback, streamOrArguments, maybeArguments)
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
  function task:start() self.started = true; return self end
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
      if value:find('"event"%s*:%s*"capture"') then
        return {
          event = "capture",
          type = "capture",
          selection = "入力",
          selected_text = "入力",
          replacement_eligible = true,
          reason = "strong_identity",
        }
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

local function startEligibleReplace()
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  ai.run(promptPath, model, "replace")
  local helper = taskAt(beforeTasks + 1, "replace mode must start the replacement helper before Gemini")
  assertTrue(helper.started, "replacement helper is started")
  assertTrue(type(helper.streamCallback) == "function", "replacement helper uses a streaming callback")
  assertTrue(helper.path ~= "/usr/bin/id" and helper.path:match("replacement%-engine$") ~= nil,
    "replace mode starts replacement-engine before account/keychain lookup")
  for _, argument in ipairs(helper.arguments or {}) do
    assert(argument ~= "入力" and argument ~= "結果", "selection/replacement content is not passed as process arguments")
  end

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

-- Cancellation: a stale Gemini callback after stop cannot write to the old helper.
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
  assertTrue(helper.path:match("replacement%-engine$") ~= nil, "replacement helper path")
  ai.run(promptPath, model, "display")
  assertTrue(helper.terminated, "new operation terminates the previous replacement helper")
end

print("ai_command_replacement_session_test: ok")
