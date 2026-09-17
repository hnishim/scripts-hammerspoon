local tasks = {}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTrue(value, message)
  assert(value == true, message)
end

local function assertNil(value, message)
  assert(value == nil, message .. ": expected nil, got " .. tostring(value))
end

local function containsArgument(arguments, expected)
  for _, value in ipairs(arguments or {}) do
    if value == expected then return true end
  end
  return false
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
  }
  function task:start() self.started = true; return self end
  function task:terminate() self.terminated = true; return self end
  function task:setStreamingCallback(fn) self.streamCallback = fn; return self end
  tasks[#tasks + 1] = task
  return task
end

local function decodeFixture(value)
  if value:find("MALFORMED", 1, true) then error("injected malformed read protocol") end
  local status = value:match('"status"%s*:%s*"([^"]+)"')
  local event = value:match('"event"%s*:%s*"([^"]+)"')
  local text = value:match('"text"%s*:%s*"([^"]*)"')
  local source = value:match('"source"%s*:%s*"([^"]+)"')
  return { event = event, status = status, text = text, source = source }
end

local frontmost = {}
function frontmost:bundleID() return "com.example.Editor" end
function frontmost:isFrontmost() return true end

_G.hs = {
  configdir = ".",
  application = { frontmostApplication = function() return frontmost end },
  task = { new = newTask },
  json = { decode = decodeFixture },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["components.powerpoint_selection"] = function()
  return {
    capture = function() error("normal read backend must not use PowerPoint") end,
    writeSelection = function() error("normal read backend must not use PowerPoint") end,
  }
end

local textIO = require("components.text_io")
local io = textIO.new({ currentBundleID = function() return "com.example.Editor" end })

local function isReplacementHelper(path)
  return type(path) == "string" and path:match("replacement%-engine$") ~= nil
end

local function startRead()
  local beforeTasks = #tasks
  local result
  local callbacks = 0
  assert(io.capture("read", function(value)
    callbacks = callbacks + 1
    result = value
  end) ~= false, "default normal read starts")
  local helper = tasks[beforeTasks + 1]
  assertTrue(helper ~= nil and helper.started, "default normal read starts a helper task")
  assertTrue(isReplacementHelper(helper.path), "normal read uses the shared Swift helper")
  assertTrue(containsArgument(helper.arguments, "read"), "normal read selects the Swift read entry")
  return helper, function() return result, callbacks end
end

local function completeRead(helper, payload, exitCode)
  if type(helper.streamCallback) == "function" then
    helper.streamCallback(helper, payload .. "\n", "")
    helper.callback(exitCode or 0, "", "")
  else
    helper.callback(exitCode or 0, payload .. "\n", "")
  end
end

local function assertReadState(payload, expectedStatus, expectedText, expectedSource)
  local helper, observe = startRead()
  completeRead(helper, payload, 0)
  local result, callbacks = observe()
  assertEqual(callbacks, 1, "read completion publishes exactly one result")
  assertEqual(result.status, expectedStatus, "read status")
  if expectedText == nil then assertNil(result.text, "read terminal state has no text")
  else assertEqual(result.text, expectedText, "read selected text") end
  if expectedSource == nil then assertNil(result.source, "read terminal state has no source")
  else assertEqual(result.source, expectedSource, "read selection source") end
  assertNil(result.replace, "read never exposes a write-back handle")
  assertEqual(#(helper.inputs or {}), 0, "read never sends replacement input")
end

assertReadState(
  '{"event":"read","status":"selected","text":"入力","source":"ax_selected_text"}',
  "selected",
  "入力",
  "ax_selected_text"
)
assertReadState('{"event":"read","status":"none"}', "none", nil, nil)
assertReadState('{"event":"read","status":"unavailable"}', "unavailable", nil, nil)
assertReadState('{"event":"read","status":"error"}', "error", nil, nil)

-- Process/protocol failure is not confused with an ordinary no-selection result.
do
  local helper, observe = startRead()
  completeRead(helper, "MALFORMED", 1)
  local result, callbacks = observe()
  assertEqual(callbacks, 1, "read protocol failure publishes one terminal result")
  assertEqual(result.status, "error", "read protocol failure maps to error")
  assertNil(result.replace, "read protocol failure exposes no write-back")
end

print("text_io_read_backend_test: ok")
