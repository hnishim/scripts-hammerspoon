local tasks = {}
local bundleID = "com.microsoft.PowerPoint"

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

local frontmost = {}
function frontmost:bundleID() return bundleID end
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
    decode = function(_) return {} end,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["components.powerpoint_selection"] = function() return powerpoint end

local textIO = require("components.text_io")
local io = textIO.new({ currentBundleID = function() return bundleID end })

local function assertNoReplacementHelper(firstIndex)
  for index = firstIndex, #tasks do
    assertTrue(not isReplacementHelper(tasks[index].path), "PowerPoint backend must not start generic replacement-engine")
  end
end

local function runPowerPointCase(id, outcome)
  bundleID = id
  powerpoint.outcome = outcome
  local beforeTasks = #tasks
  local beforeCaptures = powerpoint.captureCalls
  local beforeWrites = powerpoint.writeCalls
  local result

  assert(io.capture("replace", function(value) result = value end) ~= false, "PowerPoint replace capture starts")
  assertEqual(powerpoint.captureCalls, beforeCaptures + 1, "shared I/O selects PowerPoint capture backend")
  assertNoReplacementHelper(beforeTasks + 1)
  assertEqual(result.status, "selected", "PowerPoint selection is exposed through common status")
  assertEqual(result.text, "入力", "PowerPoint selection text is preserved")
  assertTrue(type(result.replace) == "function", "PowerPoint replace exposes common write-back handle")

  local terminal
  assert(result.replace("結果", function(value) terminal = value end) ~= false, "PowerPoint common write-back starts")
  assertEqual(powerpoint.writeCalls, beforeWrites + 1, "common write-back delegates once")
  assertEqual(powerpoint.lastSnapshot, powerpoint.snapshot, "write-back reuses the exact captured snapshot")
  assertEqual(powerpoint.lastReplacement, "結果", "write-back receives replacement text")
  assertEqual(terminal.outcome, outcome, "PowerPoint outcome keeps its existing meaning")
end

-- Both historical bundle-id spellings stay on the dedicated backend.
runPowerPointCase("com.microsoft.PowerPoint", "verified_replaced")
runPowerPointCase("com.microsoft.Powerpoint", "not_replaced")
runPowerPointCase("com.microsoft.PowerPoint", "replacement_dispatched_unverified")

-- Normal applications use the same public entry but select the Swift helper backend internally.
bundleID = "com.example.Editor"
local beforeCaptures = powerpoint.captureCalls
local beforeTasks = #tasks
local result
assert(io.capture("replace", function(value) result = value end) ~= false, "normal replace capture starts")
assertEqual(powerpoint.captureCalls, beforeCaptures, "normal route does not call PowerPoint capture")
assertTrue(tasks[beforeTasks + 1] ~= nil, "normal route creates a backend task")
assertTrue(isReplacementHelper(tasks[beforeTasks + 1].path), "normal route owns replacement-engine behind shared I/O")
assertEqual(result, nil, "normal route waits for helper capture before publishing a selection")

print("ai_command_powerpoint_routing_test: ok")
