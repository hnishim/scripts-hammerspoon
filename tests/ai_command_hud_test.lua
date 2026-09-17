local alerts = {}
local timers = {}
local tasks = {}
local httpRequests = {}
local resultShows = {}
local hudEvents = {}
local captureCalls = {}
local promptCalls = {}
local selectionResult = { status = "selected", text = "入力" }
local promptResult = { status = "cancelled" }
local taskSequence = 0

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function liveTimers()
  local count = 0
  for _, timer in ipairs(timers) do if not timer.stopped then count = count + 1 end end
  return count
end

local function fireLatestTimer()
  for index = #timers, 1, -1 do
    local timer = timers[index]
    if not timer.stopped then
      timer.stopped = true
      timer.callback()
      return
    end
  end
  error("missing live timer")
end

local function resetInputCalls()
  captureCalls, promptCalls = {}, {}
end

_G.hs = {
  alert = { show = function(message) alerts[#alerts + 1] = message end },
  timer = {
    doAfter = function(delay, callback)
      local timer = { delay = delay, callback = callback, stopped = false }
      function timer:stop() self.stopped = true end
      timers[#timers + 1] = timer
      return timer
    end,
  },
  task = {
    new = function(path, callback, arguments)
      taskSequence = taskSequence + 1
      local task = { path = path, callback = callback, arguments = arguments, started = false, terminated = false }
      function task:start() self.started = true; return true end
      function task:terminate() self.terminated = true; return true end
      tasks[#tasks + 1] = task
      return task
    end,
  },
  http = {
    asyncPost = function(url, body, headers, callback)
      httpRequests[#httpRequests + 1] = { url = url, body = body, headers = headers, callback = callback }
    end,
  },
  json = {
    encode = function(payload)
      return "PROMPT:" .. payload.contents[1].parts[1].text
    end,
    decode = function()
      return { candidates = { { content = { parts = { { text = "結果" } } } } } }
    end,
  },
  application = {
    frontmostApplication = function()
      return {
        isFrontmost = function() return true end,
        bundleID = function() return "com.example.Editor" end,
      }
    end,
  },
}

package.path = "./?.lua;" .. package.path
package.preload["components.hud"] = function()
  return {
    show = function(message) hudEvents[#hudEvents + 1] = "show:" .. message end,
    close = function() hudEvents[#hudEvents + 1] = "close" end,
  }
end
package.preload["components.result_panel"] = function()
  return {
    show = function(content) resultShows[#resultShows + 1] = content; return true end,
    stop = function() return true end,
  }
end
package.preload["components.text_io"] = function()
  return {
    capture = function(mode, callback)
      captureCalls[#captureCalls + 1] = mode
      callback(selectionResult)
      return true
    end,
  }
end
package.preload["components.text_prompt"] = function()
  return {
    request = function(options)
      promptCalls[#promptCalls + 1] = options
      return promptResult
    end,
  }
end

local ai = require("actions.ai_commands")
local promptPath = "./tests/fixtures/ai_prompt.md"
local model = "test-model"

local function completeCredentials(startIndex)
  local account = tasks[startIndex]
  assert(account and account.started, "account task is started")
  assertEqual(account.path, "/usr/bin/id", "account lookup path")
  account.callback(0, "test-account\n", "")
  local security = tasks[startIndex + 1]
  assert(security and security.started, "security task is started")
  assertEqual(security.path, "/usr/bin/security", "API key lookup path")
  security.callback(0, "test-api-key\n", "")
end

-- Display mode acquires input through the shared read boundary.
do
  resetInputCalls()
  selectionResult = { status = "selected", text = "入力" }
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforeShows = #resultShows
  assert(ai.run(promptPath, model, "display") ~= false, "display command starts")
  assertEqual(#captureCalls, 1, "display performs one capture")
  assertEqual(captureCalls[1], "read", "display uses read mode")
  assertEqual(#promptCalls, 0, "selected display input does not prompt")
  completeCredentials(beforeTasks + 1)
  assertEqual(#httpRequests, beforeRequests + 1, "display starts one HTTP request")
  local request = httpRequests[#httpRequests]
  assertEqual(request.body, "PROMPT:AI prompt: 入力", "display renders selected text")
  request.callback(200, "response", "")
  assertEqual(#resultShows, beforeShows + 1, "display shows one result")
  assertEqual(resultShows[#resultShows], "結果", "display forwards Gemini result")
  assertEqual(liveTimers(), 0, "display success leaves no watchdog")
end

-- No selection is the only read result that may enter manual input.
do
  resetInputCalls()
  selectionResult = { status = "none" }
  promptResult = { status = "submitted", text = "手入力" }
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  assert(ai.run(promptPath, model, "display") ~= false, "manual-input display starts")
  assertEqual(#captureCalls, 1, "manual-input display performs one capture")
  assertEqual(#promptCalls, 1, "no selection prompts exactly once")
  completeCredentials(beforeTasks + 1)
  assertEqual(#httpRequests, beforeRequests + 1, "manual input starts one HTTP request")
  local request = httpRequests[#httpRequests]
  assertEqual(request.body, "PROMPT:AI prompt: 手入力", "manual input is rendered")
  request.callback(200, "response", "")
end

-- Cancel is quiet, while empty/API failure remains distinguishable to the action.
do
  resetInputCalls()
  selectionResult = { status = "none" }
  promptResult = { status = "cancelled" }
  local beforeTasks = #tasks
  local beforeAlerts = #alerts
  ai.run(promptPath, model, "display")
  assertEqual(#promptCalls, 1, "cancel prompts once")
  assertEqual(#tasks, beforeTasks, "cancel starts no credentials task")
  assertEqual(#alerts, beforeAlerts, "cancel does not alert")
end

do
  resetInputCalls()
  selectionResult = { status = "none" }
  promptResult = { status = "empty" }
  local beforeTasks = #tasks
  local beforeAlerts = #alerts
  ai.run(promptPath, model, "display")
  assertEqual(#tasks, beforeTasks, "empty input starts no credentials task")
  assertEqual(#alerts, beforeAlerts + 1, "empty input alerts once")
end

do
  resetInputCalls()
  selectionResult = { status = "none" }
  promptResult = { status = "error" }
  local beforeTasks = #tasks
  local beforeAlerts = #alerts
  ai.run(promptPath, model, "display")
  assertEqual(#tasks, beforeTasks, "prompt API error starts no credentials task")
  assertEqual(#alerts, beforeAlerts + 1, "prompt API error alerts once")
end

-- Acquisition unavailable/error never falls through to the prompt.
for _, status in ipairs({ "unavailable", "error" }) do
  resetInputCalls()
  selectionResult = { status = status }
  promptResult = { status = "submitted", text = "must not be used" }
  local beforeTasks = #tasks
  local beforeAlerts = #alerts
  ai.run(promptPath, model, "display")
  assertEqual(#promptCalls, 0, "acquisition failure never prompts: " .. status)
  assertEqual(#tasks, beforeTasks, "acquisition failure starts no credentials task: " .. status)
  assertEqual(#alerts, beforeAlerts + 1, "acquisition failure alerts once: " .. status)
end

-- Configured failover retries once with the same rendered payload.
do
  resetInputCalls()
  selectionResult = { status = "selected", text = "入力" }
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforeShows = #resultShows
  assert(ai.run(promptPath, model, "display", "fallback-model") ~= false, "failover command starts")
  completeCredentials(beforeTasks + 1)
  local primary = httpRequests[beforeRequests + 1]
  primary.callback(503, "failure", "")
  assertEqual(#httpRequests, beforeRequests + 2, "primary failure starts one fallback request")
  local fallback = httpRequests[beforeRequests + 2]
  assertEqual(fallback.body, primary.body, "fallback reuses rendered payload")
  assert(fallback.url:find("fallback%-model", 1, false), "fallback uses configured model")
  fallback.callback(200, "response", "")
  assertEqual(#resultShows, beforeShows + 1, "fallback success shows one result")
  assertEqual(liveTimers(), 0, "fallback success leaves no watchdog")
end

-- HTTP timeout still releases the operation and shows a single safe error.
do
  resetInputCalls()
  selectionResult = { status = "selected", text = "入力" }
  local beforeTasks = #tasks
  local beforeAlerts = #alerts
  assert(ai.run(promptPath, model, "display") ~= false, "timeout scenario starts")
  completeCredentials(beforeTasks + 1)
  fireLatestTimer()
  assertEqual(#alerts, beforeAlerts + 1, "HTTP timeout shows one safe error")
  assertEqual(liveTimers(), 0, "HTTP timeout leaves no watchdog")
end

-- Missing prompt file fails before account/keychain work after shared input acquisition.
do
  resetInputCalls()
  selectionResult = { status = "selected", text = "入力" }
  local beforeTasks = #tasks
  local beforeAlerts = #alerts
  ai.run("./tests/fixtures/missing-ai-prompt.md", model, "display")
  assertEqual(#tasks, beforeTasks, "missing prompt starts no task")
  assertEqual(#alerts, beforeAlerts + 1, "missing prompt shows a safe error")
end

print("ai_command_hud_test: ok")
