local tasks = {}
local timers = {}
local encodedPayloads = {}
local helperTaskCreationFailure = false
local helperTaskStartFailure = false

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTrue(value, message)
  assert(value == true, message)
end

local function assertNil(value, message)
  assert(value == nil, message .. ": expected nil, got " .. tostring(value))
end

local function containsValue(value, expected)
  if value == expected then return true end
  if type(value) ~= "table" then return false end
  for _, child in pairs(value) do
    if containsValue(child, expected) then return true end
  end
  return false
end

local function isReplacementHelper(path)
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
  if helperTaskCreationFailure and isReplacementHelper(path) then return nil end
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
    if helperTaskStartFailure and isReplacementHelper(self.path) then return false end
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

local function streamTask(task, stdout, stderr)
  assert(task and type(task.streamCallback) == "function", "streaming callback is missing")
  return task.streamCallback(task, stdout or "", stderr or "")
end

local function decodeFixture(value)
  if value:find("MALFORMED", 1, true) then error("injected malformed helper protocol") end
  if value:find('"event"%s*:%s*"capture"') then
    return {
      event = "capture",
      type = "capture",
      selection = "入力",
      selected_text = "入力",
      replacement_eligible = value:find('"replacement_eligible"%s*:%s*false') == nil,
      reason = value:find("weak_identity", 1, true) and "weak_identity" or "strong_identity",
    }
  end
  local outcome = value:match('"outcome"%s*:%s*"([^"]+)"')
  if outcome then
    return { event = "outcome", type = "outcome", outcome = outcome, reason = "fixture" }
  end
  return { event = "unknown", type = "unknown" }
end

local frontmost = {}
function frontmost:bundleID() return "com.example.Editor" end
function frontmost:isFrontmost() return true end
function frontmost:activate() return true end

_G.hs = {
  configdir = ".",
  application = { frontmostApplication = function() return frontmost end },
  task = { new = newTask },
  timer = { doAfter = timerAfter },
  json = {
    encode = function(payload)
      encodedPayloads[#encodedPayloads + 1] = payload
      return "ENCODED:" .. tostring(#encodedPayloads)
    end,
    decode = decodeFixture,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["components.powerpoint_selection"] = function()
  return {
    capture = function() error("normal backend must not capture PowerPoint") end,
    writeSelection = function() error("normal backend must not write PowerPoint") end,
  }
end

local textIO = require("components.text_io")
local io = textIO.new({ currentBundleID = function() return "com.example.Editor" end })

local function startPendingCapture()
  local beforeTasks = #tasks
  local result
  local callbacks = 0
  assert(io.capture("replace", function(value)
    callbacks = callbacks + 1
    result = value
  end) ~= false, "normal replace capture starts")
  local helper = tasks[beforeTasks + 1]
  assertTrue(helper ~= nil and helper.started, "shared I/O starts replacement helper")
  assertTrue(isReplacementHelper(helper.path), "helper ownership is inside shared I/O")
  assertTrue(type(helper.streamCallback) == "function", "helper session keeps a streaming callback")
  assertNil(result, "selection is not published before helper capture")
  return helper, function() return result, callbacks end
end

local function startCapture(eligible)
  local helper, observe = startPendingCapture()
  streamTask(helper,
    '{"event":"capture","selection":"入力","replacement_eligible":' .. (eligible and "true" or "false") ..
      ',"reason":"' .. (eligible and "strong_identity" or "weak_identity") .. '"}\n', "")
  local result, callbacks = observe()
  assertEqual(callbacks, 1, "helper capture publishes one result")
  assertEqual(result.status, "selected", "helper capture maps to common selected state")
  assertEqual(result.text, "入力", "helper selection is preserved")
  assertTrue(type(result.replace) == "function", "replace mode publishes one safe write-back handle")
  return helper, result
end

local function runTerminalOutcome(outcome)
  local helper, result = startCapture(true)
  local beforeEncoded = #encodedPayloads
  local terminal
  assert(result.replace("結果", function(value) terminal = value end) ~= false, "write-back starts")
  assertEqual(#helper.inputs, 1, "replacement is sent exactly once to the held helper")
  assertTrue(#encodedPayloads > beforeEncoded, "replacement command is JSON-encoded by shared I/O")
  assertTrue(containsValue(encodedPayloads[#encodedPayloads], "結果"), "encoded command contains replacement text")
  assertNil(terminal, "outcome waits for helper terminal event")
  streamTask(helper, '{"event":"outcome","outcome":"' .. outcome .. '","reason":"fixture"}\n', "")
  assertEqual(terminal.outcome, outcome, "terminal outcome keeps helper meaning: " .. outcome)
end

-- The same helper session is held across capture -> caller work -> write-back -> terminal outcome.
for _, outcome in ipairs({ "verified_replaced", "replacement_dispatched_unverified", "not_replaced", "error" }) do
  runTerminalOutcome(outcome)
end

-- Weak identity can supply input, but the common write-back handle refuses mutation without sending payload.
do
  local helper, result = startCapture(false)
  local terminal
  local beforeInputs = #helper.inputs
  assert(result.replace("結果", function(value) terminal = value end) ~= false, "weak-identity refusal is a valid terminal operation")
  assertEqual(#helper.inputs, beforeInputs, "weak identity never receives a replacement payload")
  assertEqual(terminal.outcome, "not_replaced", "weak identity maps to safe no-mutation outcome")
end

-- Helper creation failure is exposed as a common acquisition error and never starts a session.
do
  local result
  helperTaskCreationFailure = true
  local started = io.capture("replace", function(value) result = value end)
  helperTaskCreationFailure = false
  assertEqual(started, false, "helper creation failure cannot report capture start")
  assertEqual(result.status, "error", "helper creation failure maps to common error state")
end

-- Helper start failure is fail-closed and exposes no selection/write-back capability.
do
  local result
  helperTaskStartFailure = true
  local started = io.capture("replace", function(value) result = value end)
  helperTaskStartFailure = false
  assertEqual(started, false, "helper start failure cannot report capture start")
  assertEqual(result.status, "error", "helper start failure maps to common error state")
  assertNil(result.replace, "failed helper start exposes no write-back")
end

-- Nonzero exit before capture cannot publish a selection or mutation capability.
do
  local beforeTasks = #tasks
  local result
  assert(io.capture("replace", function(value) result = value end) ~= false, "pre-exit capture starts")
  local helper = tasks[beforeTasks + 1]
  helper.callback(1, "", "permission denied")
  assertEqual(result.status, "error", "pre-capture helper exit maps to error")
  assertNil(result.replace, "pre-capture helper exit exposes no write-back")
  assertEqual(#helper.inputs, 0, "pre-capture helper exit cannot mutate")
end

-- Malformed helper protocol terminates the session without publishing mutation capability.
do
  local beforeTasks = #tasks
  local result
  assert(io.capture("replace", function(value) result = value end) ~= false, "malformed-protocol capture starts")
  local helper = tasks[beforeTasks + 1]
  streamTask(helper, "MALFORMED\n", "")
  assertEqual(result.status, "error", "malformed helper protocol maps to error")
  assertTrue(helper.terminated, "malformed helper protocol terminates helper")
  assertEqual(#helper.inputs, 0, "malformed helper protocol cannot mutate")
end

-- Capture timeout terminates the helper and a later stale event cannot revive the session.
do
  local helper, observe = startPendingCapture()
  assertTrue(liveTimers() > 0, "replace capture arms a watchdog")
  fireLatestTimer()
  local result, callbacks = observe()
  assertTrue(helper.terminated, "capture timeout terminates helper")
  assertEqual(callbacks, 1, "capture timeout publishes one terminal result")
  assertEqual(result.status, "error", "capture timeout maps to error")
  assertNil(result.replace, "capture timeout exposes no write-back")
  local beforeCallbacks = callbacks
  streamTask(helper, '{"event":"capture","selection":"入力","replacement_eligible":true,"reason":"strong_identity"}\n', "")
  local staleResult, afterCallbacks = observe()
  assertEqual(afterCallbacks, beforeCallbacks, "stale capture after timeout is ignored")
  assertEqual(staleResult.status, "error", "stale capture does not replace terminal error")
  assertEqual(#helper.inputs, 0, "stale capture after timeout cannot mutate")
end

-- Explicit stop terminates the owned helper and ignores later helper events.
do
  local helper, observe = startPendingCapture()
  local _, beforeCallbacks = observe()
  assert(io.stop() ~= false, "common I/O stop is accepted")
  assertTrue(helper.terminated, "common I/O stop terminates helper")
  streamTask(helper, '{"event":"capture","selection":"入力","replacement_eligible":true,"reason":"strong_identity"}\n', "")
  local result, afterCallbacks = observe()
  assertEqual(afterCallbacks, beforeCallbacks, "stale capture after stop is ignored")
  assertNil(result, "explicit stop does not publish a stale selection")
  assertEqual(#helper.inputs, 0, "stale capture after stop cannot mutate")
end

-- Starting another capture terminates the still-pending previous helper before owning a new session.
do
  local firstHelper = startPendingCapture()
  local beforeTasks = #tasks
  local secondResult
  assert(io.capture("replace", function(value) secondResult = value end) ~= false, "second capture starts")
  assertTrue(firstHelper.terminated, "new capture terminates previous helper")
  local secondHelper = tasks[beforeTasks + 1]
  assertTrue(secondHelper ~= nil and secondHelper.started, "new capture owns a new helper")
  assertNil(secondResult, "second capture still waits for its own helper event")
  io.stop()
end

print("ai_command_replacement_session_test: ok")
