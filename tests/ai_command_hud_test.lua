local alerts = {}
local timers = {}
local tasks = {}
local httpRequests = {}
local resultShows = {}
local hudEvents = {}
local clipboard = "prior clipboard"
local clipboardCount = 1
local clipboardItems = { ["public.utf8-plain-text"] = "prior clipboard" }
local clipboardTypes = { { "public.utf8-plain-text" } }
local focusedSelection = "入力"
local copyResult = "コピー入力"
local copyFailure = false
local frontmost = true
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
  dialog = {
    textPrompt = function() return "キャンセル", "" end,
  },
  uielement = {
    focusedElement = function()
      if focusedSelection == "missing" then return nil end
      return {
        selectedText = function()
          if focusedSelection == "error" then error("selectedText failure") end
          return focusedSelection
        end,
      }
    end,
  },
  pasteboard = {
    getContents = function() return clipboard end,
    changeCount = function() return clipboardCount end,
    allContentTypes = function()
      local result = {}
      for i, item in ipairs(clipboardTypes) do
        result[i] = {}
        for j, value in ipairs(item) do result[i][j] = value end
      end
      return result
    end,
    readAllData = function()
      local result = {}
      for key, value in pairs(clipboardItems) do result[key] = value end
      return result
    end,
    writeAllData = function(data)
      clipboardItems = {}
      for key, value in pairs(data) do clipboardItems[key] = value end
      clipboard = clipboardItems["public.utf8-plain-text"]
      clipboardTypes = { { "public.utf8-plain-text" } }
      clipboardCount = clipboardCount + 1
      return true
    end,
    clearContents = function()
      clipboard = nil
      clipboardItems = {}
      clipboardTypes = {}
      clipboardCount = clipboardCount + 1
      return true
    end,
  },
  eventtap = {
    keyStroke = function(modifiers, key)
      assertEqual(table.concat(modifiers, "+"), "cmd", "display fallback uses Command")
      assertEqual(key, "c", "display fallback uses Command-C")
      if copyFailure then error("copy failure") end
      clipboard = copyResult
      clipboardItems = { ["public.utf8-plain-text"] = copyResult }
      clipboardTypes = { { "public.utf8-plain-text" } }
      clipboardCount = clipboardCount + 1
      return true
    end,
  },
  application = {
    frontmostApplication = function()
      return {
        isFrontmost = function() return frontmost end,
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

local ai = require("actions.ai_commands")
local promptPath = "./tests/fixtures/ai_prompt.md"
local model = "test-model"

local function completeCredentials(startIndex)
  local account = tasks[startIndex]
  assert(account and account.started, "account task is started")
  account.callback(0, "test-account\n", "")
  local security = tasks[startIndex + 1]
  assert(security and security.started, "security task is started")
  security.callback(0, "test-api-key\n", "")
end

-- Display mode keeps the pre-HIR-235 contract: direct selection -> Gemini -> result panel.
do
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforeShows = #resultShows
  assertEqual(ai.run(promptPath, model, "display"), true, "display command starts")
  completeCredentials(beforeTasks + 1)
  assertEqual(#httpRequests, beforeRequests + 1, "display starts one HTTP request")
  local request = httpRequests[#httpRequests]
  assertEqual(request.body, "PROMPT:AI prompt: 入力", "display renders selected text")
  request.callback(200, "response", "")
  assertEqual(#resultShows, beforeShows + 1, "display shows one result")
  assertEqual(resultShows[#resultShows], "結果", "display forwards Gemini result")
  assertEqual(liveTimers(), 0, "display success leaves no watchdog")
end

-- Configured failover retries once with the same rendered payload.
do
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforeShows = #resultShows
  assertEqual(ai.run(promptPath, model, "display", "fallback-model"), true, "failover command starts")
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

-- HTTP timeout releases the operation and shows a single safe error.
do
  local beforeTasks = #tasks
  local beforeAlerts = #alerts
  assertEqual(ai.run(promptPath, model, "display"), true, "timeout scenario starts")
  completeCredentials(beforeTasks + 1)
  fireLatestTimer()
  assertEqual(#alerts, beforeAlerts + 1, "HTTP timeout shows one safe error")
  assertEqual(liveTimers(), 0, "HTTP timeout leaves no watchdog")
end

-- Missing prompt fails before account/keychain work.
do
  local beforeTasks = #tasks
  local beforeAlerts = #alerts
  ai.run("./tests/fixtures/missing-ai-prompt.md", model, "display")
  assertEqual(#tasks, beforeTasks, "missing prompt starts no task")
  assertEqual(#alerts, beforeAlerts + 1, "missing prompt shows a safe error")
end

-- When AX selected text is unavailable, display mode uses Command-C only for input,
-- restores the prior clipboard, and then continues through the normal Gemini path.
do
  focusedSelection = nil
  clipboard = "rich prior"
  clipboardCount = 10
  clipboardItems = {
    ["public.utf8-plain-text"] = "rich prior",
    ["public.rtf"] = "{\\rtf1 rich prior}",
  }
  clipboardTypes = { { "public.utf8-plain-text", "public.rtf" } }
  copyResult = "fallback input"
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforeShows = #resultShows
  assertEqual(ai.run(promptPath, model, "display"), true, "clipboard fallback starts")
  fireLatestTimer()
  assertEqual(clipboard, "rich prior", "clipboard fallback restores prior text")
  assertEqual(clipboardItems["public.rtf"], "{\\rtf1 rich prior}", "clipboard fallback restores rich data")
  completeCredentials(beforeTasks + 1)
  assertEqual(#httpRequests, beforeRequests + 1, "clipboard fallback starts Gemini")
  local request = httpRequests[#httpRequests]
  assertEqual(request.body, "PROMPT:AI prompt: fallback input", "copied input is rendered")
  request.callback(200, "response", "")
  assertEqual(#resultShows, beforeShows + 1, "clipboard fallback shows one result")
end

-- Copy failure is fail-closed and never starts Gemini.
do
  focusedSelection = nil
  copyFailure = true
  clipboard = "before failure"
  clipboardCount = 20
  clipboardItems = { ["public.utf8-plain-text"] = "before failure" }
  clipboardTypes = { { "public.utf8-plain-text" } }
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforeAlerts = #alerts
  ai.run(promptPath, model, "display")
  assertEqual(#tasks, beforeTasks, "copy failure starts no task")
  assertEqual(#httpRequests, beforeRequests, "copy failure starts no HTTP request")
  assertEqual(#alerts, beforeAlerts + 1, "copy failure shows one safe error")
  assertEqual(clipboard, "before failure", "copy failure preserves clipboard")
  copyFailure = false
end

print("ai_command_hud_test: ok")
