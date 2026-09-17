local tasks = {}
local timers = {}
local httpRequests = {}
local resultPanelShows = {}
local alerts = {}
local frontmostBundle = "com.microsoft.Powerpoint"

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTrue(value, message)
  assert(value == true, message)
end

local function isReplacementHelper(path)
  return type(path) == "string" and path:match("replacement%-engine$") ~= nil
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
    started = false,
    terminated = false,
    inputs = {},
  }
  function task:start() self.started = true; return self end
  function task:terminate() self.terminated = true; return self end
  function task:setInput(value) self.inputs[#self.inputs + 1] = value; return self end
  tasks[#tasks + 1] = task
  return task
end

local function completeTask(task, exitCode, stdout, stderr)
  assert(task and task.callback, "task callback is missing")
  task.callback(exitCode or 0, stdout or "", stderr or "")
end

local frontmost = {}
function frontmost:bundleID() return frontmostBundle end
function frontmost:isFrontmost() return true end
function frontmost:activate() return true end

local powerpoint = {
  captureCalls = 0,
  writeCalls = 0,
  outcome = "verified_replaced",
  snapshot = { selectedText = "入力", slideID = 101, textOffset = 3, textLength = 2 },
}
function powerpoint.capture()
  powerpoint.captureCalls = powerpoint.captureCalls + 1
  return powerpoint.snapshot
end
function powerpoint.writeSelection(snapshot, replacement)
  powerpoint.writeCalls = powerpoint.writeCalls + 1
  powerpoint.lastSnapshot = snapshot
  powerpoint.lastReplacement = replacement
  return powerpoint.outcome, "fixture"
end

_G.hs = {
  configdir = ".",
  alert = { show = function(message) alerts[#alerts + 1] = message end },
  timer = {
    doAfter = function(delay, callback)
      local timer = { delay = delay, callback = callback, stopped = false }
      function timer:stop() self.stopped = true end
      timers[#timers + 1] = timer
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
    encode = function(_) return "ENCODED" end,
    decode = function(value)
      if value == "GEMINI" then
        return { candidates = { { content = { parts = { { text = "結果" } } } } } }
      end
      return {}
    end,
  },
  application = { frontmostApplication = function() return frontmost end },
  uielement = {
    focusedElement = function()
      return { selectedText = function() return "generic-input" end }
    end,
  },
  pasteboard = {
    getContents = function() return "prior" end,
    changeCount = function() return 1 end,
    allContentTypes = function() return { { "public.utf8-plain-text" } } end,
    readAllData = function() return { ["public.utf8-plain-text"] = "prior" } end,
    writeAllData = function() return true end,
    clearContents = function() return true end,
  },
  eventtap = { keyStroke = function() return true end },
  dialog = { textPrompt = function() return "キャンセル", "" end },
}

package.path = "./?.lua;" .. package.path
package.preload["components.hud"] = function()
  return { show = function() return true end, close = function() return true end }
end
package.preload["components.result_panel"] = function()
  return {
    show = function(content) resultPanelShows[#resultPanelShows + 1] = content; return true end,
    stop = function() return true end,
    close = function() return true end,
  }
end
package.preload["components.powerpoint_selection"] = function() return powerpoint end

local ai = require("actions.ai_commands")
local promptPath = "./tests/fixtures/ai_prompt.md"
local model = "test-model"

local function completeCredentials(firstTaskIndex)
  local account = tasks[firstTaskIndex]
  assert(account, "account task is missing")
  assertEqual(account.path, "/usr/bin/id", "PowerPoint route starts account lookup without replacement helper")
  completeTask(account, 0, "test-account\n", "")
  local security = tasks[firstTaskIndex + 1]
  assert(security, "security task is missing")
  assertEqual(security.path, "/usr/bin/security", "PowerPoint route reads API key")
  completeTask(security, 0, "test-api-key\n", "")
end

local function assertNoHelperSince(firstTaskIndex)
  for index = firstTaskIndex, #tasks do
    assertTrue(not isReplacementHelper(tasks[index].path), "PowerPoint replace route must not start generic replacement-engine")
  end
end

local function runPowerPointCase(outcome)
  powerpoint.outcome = outcome
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  local beforeCaptures = powerpoint.captureCalls
  local beforeWrites = powerpoint.writeCalls
  local beforePanels = #resultPanelShows

  local started = ai.run(promptPath, model, "replace")
  assertTrue(started ~= false, "PowerPoint replace route starts")
  assertEqual(powerpoint.captureCalls, beforeCaptures + 1, "PowerPoint route captures selection before Gemini")
  assertNoHelperSince(beforeTasks + 1)
  completeCredentials(beforeTasks + 1)
  assertEqual(#httpRequests, beforeRequests + 1, "PowerPoint capture starts one Gemini request")
  httpRequests[#httpRequests].callback(200, "GEMINI", "")
  assertEqual(powerpoint.writeCalls, beforeWrites + 1, "Gemini result is returned to the captured PowerPoint selection")
  assertEqual(powerpoint.lastSnapshot, powerpoint.snapshot, "same capture snapshot is revalidated for write")
  assertEqual(powerpoint.lastReplacement, "結果", "Gemini response is the replacement payload")

  if outcome == "not_replaced" then
    assertEqual(#resultPanelShows, beforePanels + 1, "safe pre-write refusal displays the computed result once")
    assertEqual(resultPanelShows[#resultPanelShows], "結果", "fallback panel receives the computed result")
  else
    assertEqual(#resultPanelShows, beforePanels, "terminal PowerPoint mutation outcome never duplicates result panel")
  end
end

-- Bug case: PowerPoint replace must bypass the generic Swift AX session.
runPowerPointCase("verified_replaced")

-- Safe pre-write refusal falls back exactly once because mutation did not happen.
runPowerPointCase("not_replaced")

-- Dispatch with uncertain postcondition is terminal to prevent duplicate mutation/panel output.
runPowerPointCase("replacement_dispatched_unverified")

-- Adjacent regression: non-PowerPoint replace still uses the existing Swift helper session.
frontmostBundle = "com.example.Editor"
local beforeTasks = #tasks
local beforeCaptures = powerpoint.captureCalls
local started = ai.run(promptPath, model, "replace")
assertTrue(started ~= false, "generic replace route starts")
assertEqual(powerpoint.captureCalls, beforeCaptures, "generic route does not call PowerPoint capture")
assertTrue(tasks[beforeTasks + 1] ~= nil and isReplacementHelper(tasks[beforeTasks + 1].path),
  "non-PowerPoint replace keeps the replacement-engine helper path")
ai.stop()

print("ai_command_powerpoint_routing_test: ok")
