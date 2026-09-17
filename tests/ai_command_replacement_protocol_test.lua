local tasks = {}

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
    inputs = {},
    started = false,
    terminated = false,
  }
  function task:start() self.started = true; return self end
  function task:terminate() self.terminated = true; return self end
  function task:setInput(value) self.inputs[#self.inputs + 1] = value; return self end
  function task:closeInput() return self end
  function task:setStreamingCallback(fn) self.streamCallback = fn; return self end
  tasks[#tasks + 1] = task
  return task
end

local function decodeFixture(value)
  if value:find("missing_eligibility", 1, true) then
    return { event = "capture", type = "capture", selection = "入力", reason = "fixture" }
  end
  if value:find("string_eligibility", 1, true) then
    return {
      event = "capture", type = "capture", selection = "入力", replacement_eligible = "true", reason = "fixture",
    }
  end
  if value:find("missing_selection", 1, true) then
    return { event = "capture", type = "capture", replacement_eligible = true, reason = "fixture" }
  end
  if value:find("non_string_selection", 1, true) then
    return { event = "capture", type = "capture", selection = 42, replacement_eligible = true, reason = "fixture" }
  end
  if value:find("unknown_event", 1, true) then
    return { event = "unknown", type = "unknown", reason = "fixture" }
  end
  if value:find("outcome_before_capture", 1, true) then
    return { event = "outcome", type = "outcome", outcome = "not_replaced", reason = "fixture" }
  end
  if value:find("valid_capture", 1, true) then
    return {
      event = "capture", type = "capture", selection = "入力", selected_text = "入力",
      replacement_eligible = true, reason = "fixture",
    }
  end
  return {}
end

local frontmost = {}
function frontmost:bundleID() return "com.example.Editor" end
function frontmost:isFrontmost() return true end

_G.hs = {
  configdir = ".",
  application = { frontmostApplication = function() return frontmost end },
  task = { new = newTask },
  timer = {
    doAfter = function(_, callback)
      local timer = { callback = callback, stopped = false }
      function timer:stop() self.stopped = true end
      return timer
    end,
  },
  json = {
    encode = function(_) return "ENCODED" end,
    decode = decodeFixture,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["components.powerpoint_selection"] = function()
  return {
    capture = function() error("normal backend must not use PowerPoint") end,
    writeSelection = function() error("normal backend must not use PowerPoint") end,
  }
end

local textIO = require("components.text_io")
local io = textIO.new({ currentBundleID = function() return "com.example.Editor" end })

local function startSession()
  local beforeTasks = #tasks
  local result
  assert(io.capture("replace", function(value) result = value end) ~= false, "protocol fixture capture starts")
  local helper = tasks[beforeTasks + 1]
  assertTrue(helper ~= nil and helper.started, "protocol fixture starts helper")
  assertTrue(isReplacementHelper(helper.path), "protocol validation lives on shared I/O helper boundary")
  return helper, function() return result end
end

local function assertInvalidCapture(payload, label)
  local helper, result = startSession()
  helper.streamCallback(helper, payload .. "\n", "")
  local value = result()
  assertEqual(value.status, "error", label .. " maps to common error")
  assertTrue(helper.terminated, label .. " terminates helper")
  assertEqual(#helper.inputs, 0, label .. " cannot send replacement input")
  assert(value.replace == nil, label .. " exposes no write-back handle")
end

assertInvalidCapture(
  '{"event":"capture","selection":"入力","reason":"fixture","fixture_case":"missing_eligibility"}',
  "capture missing replacement_eligible"
)
assertInvalidCapture(
  '{"event":"capture","selection":"入力","replacement_eligible":"true","fixture_case":"string_eligibility"}',
  "capture with non-boolean replacement_eligible"
)
assertInvalidCapture(
  '{"event":"capture","replacement_eligible":true,"fixture_case":"missing_selection"}',
  "capture missing selection"
)
assertInvalidCapture(
  '{"event":"capture","selection":42,"replacement_eligible":true,"fixture_case":"non_string_selection"}',
  "capture with non-string selection"
)
assertInvalidCapture('{"event":"unknown","fixture_case":"unknown_event"}', "unknown helper event before capture")
assertInvalidCapture(
  '{"event":"outcome","outcome":"not_replaced","fixture_case":"outcome_before_capture"}',
  "terminal outcome before capture"
)

-- Control: a valid capture is accepted and keeps the session available for a later safe write-back.
do
  local helper, result = startSession()
  helper.streamCallback(helper, '{"event":"capture","selection":"入力","replacement_eligible":true,"fixture_case":"valid_capture"}\n', "")
  local value = result()
  assertEqual(value.status, "selected", "valid capture is accepted")
  assertEqual(value.text, "入力", "valid capture preserves selection")
  assertTrue(type(value.replace) == "function", "valid replace capture exposes write-back handle")
  assertEqual(helper.terminated, false, "valid capture keeps helper session alive")
end

print("ai_command_replacement_protocol_test: ok")
