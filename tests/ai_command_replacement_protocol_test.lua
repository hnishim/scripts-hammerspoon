local tasks = {}
local timers = {}
local httpRequests = {}
local alerts = {}
local resultPanelShows = {}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTrue(value, message)
  assert(value == true, message)
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
  }
  function task:start() self.started = true; return self end
  function task:terminate() self.terminated = true; return self end
  function task:setInput(value) self.inputs[#self.inputs + 1] = value; return self end
  function task:closeInput() return self end
  tasks[#tasks + 1] = task
  return task
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
    encode = function(_) return "ENCODED" end,
    decode = function(value)
      if value:find('"fixture_case"%s*:%s*"missing_eligibility"') then
        return {
          event = "capture",
          type = "capture",
          selection = "入力",
          selected_text = "入力",
          reason = "missing_eligibility",
        }
      end
      if value:find('"fixture_case"%s*:%s*"string_eligibility"') then
        return {
          event = "capture",
          type = "capture",
          selection = "入力",
          selected_text = "入力",
          replacement_eligible = "true",
          reason = "invalid_eligibility_type",
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
    show = function() end,
    close = function() end,
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

local function startReplacementHelper()
  local beforeTasks = #tasks
  local beforeRequests = #httpRequests
  ai.run(promptPath, model, "replace")
  local helper = tasks[beforeTasks + 1]
  assert(helper, "replace mode must create a helper task")
  assertTrue(helper.started, "replacement helper is started")
  assertTrue(isReplacementHelperPath(helper.path), "replace mode starts replacement-engine first")
  assertTrue(type(helper.streamCallback) == "function", "replacement helper uses a streaming callback")
  assertEqual(#httpRequests, beforeRequests, "Gemini does not start before a valid capture")
  return helper, beforeRequests
end

local function assertInvalidCaptureFailsClosed(payload, label)
  local beforePanels = #resultPanelShows
  local helper, beforeRequests = startReplacementHelper()
  streamTask(helper, payload .. "\n", "")
  assertTrue(helper.terminated, label .. " terminates the helper")
  assertEqual(#httpRequests, beforeRequests, label .. " does not start Gemini")
  assertEqual(#helper.inputs, 0, label .. " cannot send replacement input")
  assertEqual(#resultPanelShows, beforePanels, label .. " does not show a duplicate result panel")
end

assertInvalidCaptureFailsClosed(
  '{"event":"capture","selection":"入力","reason":"fixture","fixture_case":"missing_eligibility"}',
  "capture missing replacement_eligible"
)

assertInvalidCaptureFailsClosed(
  '{"event":"capture","selection":"入力","replacement_eligible":"true","reason":"fixture","fixture_case":"string_eligibility"}',
  "capture with non-boolean replacement_eligible"
)

print("ai_command_replacement_protocol_test: ok")
