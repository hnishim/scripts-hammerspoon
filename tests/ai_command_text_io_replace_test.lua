local tasks = {}
local httpRequests = {}
local resultShows = {}
local alerts = {}
local captureCalls = {}
local replaceCalls = {}
local stopCalls = 0
local bundleID = "com.example.Editor"
local replacementOutcome = "verified_replaced"

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function isReplacementHelper(path)
  return type(path) == "string" and path:match("replacement%-engine$") ~= nil
end

local function newTask(path, callback, arguments)
  local task = { path = path, callback = callback, arguments = arguments or {}, started = false, terminated = false }
  function task:start() self.started = true; return self end
  function task:terminate() self.terminated = true; return self end
  tasks[#tasks + 1] = task
  return task
end

_G.hs = {
  alert = { show = function(message) alerts[#alerts + 1] = message end },
  timer = {
    doAfter = function(_, callback)
      local timer = { callback = callback, stopped = false }
      function timer:stop() self.stopped = true end
      return timer
    end,
  },
  task = { new = newTask },
  http = {
    asyncPost = function(url, body, headers, callback)
      httpRequests[#httpRequests + 1] = { url = url, body = body, headers = headers, callback = callback }
    end,
  },
  json = {
    encode = function(payload) return "PROMPT:" .. payload.contents[1].parts[1].text end,
    decode = function()
      return {
        candidates = {
          {
            content = {
              parts = {
                { text = "結果" },
              },
            },
          },
        },
      }
    end,
  },
  application = {
    frontmostApplication = function()
      return {
        isFrontmost = function() return true end,
        bundleID = function() return bundleID end,
      }
    end,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["components.hud"] = function()
  return { show = function() return true end, close = function() return true end }
end
package.preload["components.result_panel"] = function()
  return {
    show = function(content) resultShows[#resultShows + 1] = content; return true end,
    stop = function() return true end,
    close = function() return true end,
  }
end
package.preload["components.text_prompt"] = function()
  return { request = function() return { status = "cancelled" } end }
end
local textIOStub = {
  capture = function(mode, callback)
    captureCalls[#captureCalls + 1] = mode
    callback({
      status = "selected",
      text = "入力",
      replace = function(replacement, outcomeCallback)
        replaceCalls[#replaceCalls + 1] = replacement
        outcomeCallback({ outcome = replacementOutcome, reason = "fixture" })
        return true
      end,
    })
    return true
  end,
  stop = function()
    stopCalls = stopCalls + 1
    return true
  end,
}
package.preload["components.text_io"] = function() return textIOStub end
package.preload["components.powerpoint_selection"] = function()
  return {
    capture = function() error("AI action must not call PowerPoint selection directly") end,
    writeSelection = function() error("AI action must not write PowerPoint selection directly") end,
  }
end

local ai = require("actions.ai_commands")
local promptPath = "./tests/fixtures/ai_prompt.md"
local model = "test-model"

local function completeCredentials(firstIndex)
  local account = tasks[firstIndex]
  assert(account and account.started, "account task is started")
  assertEqual(account.path, "/usr/bin/id", "account lookup path")
  account.callback(0, "test-account\n", "")
  local security = tasks[firstIndex + 1]
  assert(security and security.started, "security task is started")
  assertEqual(security.path, "/usr/bin/security", "keychain path")
  security.callback(0, "test-api-key\n", "")
end

local function assertNoReplacementHelper(firstIndex)
  for index = firstIndex, #tasks do
    assert(not isReplacementHelper(tasks[index].path), "AI action must not own replacement-engine after common I/O migration")
  end
end

local function runReplaceCase(targetBundle, outcome, expectPanel, expectedAlerts)
  bundleID = targetBundle
  replacementOutcome = outcome
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforeCaptures = #captureCalls
  local beforeReplacements = #replaceCalls
  local beforePanels = #resultShows
  local beforeAlerts = #alerts

  assert(ai.run(promptPath, model, "replace") ~= false, "replace command starts")
  assertEqual(#captureCalls, beforeCaptures + 1, "replace performs one shared capture")
  assertEqual(captureCalls[#captureCalls], "replace", "AI replace uses common replace mode")
  assertNoReplacementHelper(beforeTasks + 1)

  completeCredentials(beforeTasks + 1)
  assertEqual(#httpRequests, beforeRequests + 1, "selected replacement starts Gemini")
  local request = httpRequests[#httpRequests]
  assertEqual(request.body, "PROMPT:AI prompt: 入力", "captured text reaches Gemini")
  request.callback(200, "response", "")

  assertEqual(#replaceCalls, beforeReplacements + 1, "Gemini result is sent through shared write-back handle")
  assertEqual(replaceCalls[#replaceCalls], "結果", "shared write-back receives Gemini result")
  if expectPanel then
    assertEqual(#resultShows, beforePanels + 1, "safe no-mutation outcome shows computed result once")
    assertEqual(resultShows[#resultShows], "結果", "fallback panel receives Gemini result")
  else
    assertEqual(#resultShows, beforePanels, "terminal replacement outcome does not duplicate result panel")
  end
  assertEqual(#alerts, beforeAlerts + (expectedAlerts or 0), "replacement outcome alert count")
end

-- Generic editable applications enter the shared replace boundary; action code no longer owns the Swift helper session.
runReplaceCase("com.example.Editor", "verified_replaced", false, 0)

-- A safe refusal remains display-only without bypassing the common write-back boundary.
runReplaceCase("com.example.Editor", "not_replaced", true, 0)

-- Dispatch with uncertain postcondition is terminal: no duplicate panel, no second mutation, no error alert.
runReplaceCase("com.example.Editor", "replacement_dispatched_unverified", false, 0)

-- Common write-back errors fail safely without exposing a duplicate result panel.
runReplaceCase("com.example.Editor", "error", false, 1)

-- PowerPoint uses the same action-level replace contract; backend selection is hidden inside text_io.
runReplaceCase("com.microsoft.PowerPoint", "verified_replaced", false, 0)

-- Explicit AI stop delegates replacement-session cancellation to the shared I/O owner.
do
  bundleID = "com.example.Editor"
  replacementOutcome = "verified_replaced"
  local beforeTasks = #tasks
  local beforeStops = stopCalls
  assert(ai.run(promptPath, model, "replace") ~= false, "replace command starts before explicit stop")
  assert(tasks[beforeTasks + 1] and tasks[beforeTasks + 1].started, "credential task starts after capture")
  ai.stop()
  assertEqual(stopCalls, beforeStops + 1, "AI stop delegates once to shared text I/O")
end

-- Stopping after Gemini dispatch invalidates the operation; a delayed success callback cannot write back or publish stale UI.
do
  bundleID = "com.example.Editor"
  replacementOutcome = "verified_replaced"
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforeReplacements = #replaceCalls
  local beforePanels = #resultShows
  local beforeAlerts = #alerts
  local beforeStops = stopCalls

  assert(ai.run(promptPath, model, "replace") ~= false, "replace command starts before delayed callback cancellation")
  completeCredentials(beforeTasks + 1)
  assertEqual(#httpRequests, beforeRequests + 1, "replace dispatches Gemini before cancellation")
  local staleRequest = httpRequests[#httpRequests]

  ai.stop()
  assertEqual(stopCalls, beforeStops + 1, "AI stop cancels shared text I/O after Gemini dispatch")

  staleRequest.callback(200, "response", "")
  assertEqual(#replaceCalls, beforeReplacements, "stale Gemini callback cannot invoke shared write-back")
  assertEqual(#resultShows, beforePanels, "stale Gemini callback cannot publish a result panel")
  assertEqual(#alerts, beforeAlerts, "stale Gemini callback cannot publish an additional error")
end

print("ai_command_text_io_replace_test: ok")
