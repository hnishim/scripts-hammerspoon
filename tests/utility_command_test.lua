local bindings = {}
local taskCallbacks = {}
local taskReferences = setmetatable({}, { __mode = "v" })
local taskCalls = {}
local alerts = {}
local taskMode = { new = nil, start = nil }
local taskSequence = 0
local raycastRoot = (os.getenv("HOME") or "") .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast"

local function signature(modifiers, key)
  return table.concat(modifiers, "+") .. ":" .. key
end

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTable(actual, expected, message)
  assertEqual(#actual, #expected, message .. " length")
  for index, value in ipairs(expected) do assertEqual(actual[index], value, message .. "[" .. index .. "]") end
end

_G.hs = {
  alert = {
    show = function(message) alerts[#alerts + 1] = message end,
  },
  hotkey = {
    bind = function(modifiers, key, callback)
      bindings[signature(modifiers, key)] = callback
    end,
  },
  task = {
    new = function(path, callback, arguments)
      if taskMode.new == "nil" then return nil end
      if taskMode.new == "error" then error("task creation failure") end
      taskSequence = taskSequence + 1
      local id = taskSequence
      local task = {
        start = function()
          if taskMode.start == "error" then error("task start failure") end
          if taskMode.start == "false" then return false end
          return true
        end,
      }
      taskCallbacks[id] = callback
      taskReferences[id] = task
      taskCalls[id] = { path = path, arguments = arguments }
      return task
    end,
  },
}

package.path = "./?.lua;" .. package.path
local utilityCommand = require("utility_command")
utilityCommand.start()

local function press(modifiers, key)
  local callback = bindings[signature(modifiers, key)]
  assert(callback, "missing binding " .. signature(modifiers, key))
  callback()
  return taskSequence
end

local function complete(id, exitCode, stdout, stderr)
  local callback = taskCallbacks[id]
  assert(callback, "missing task callback " .. tostring(id))
  callback(exitCode, stdout, stderr)
  taskCallbacks[id] = nil
end

local function assertTask(id, pathSuffix, expectedArguments)
  local call = taskCalls[id]
  assert(call, "missing task call " .. tostring(id))
  assert(call.path:sub(-#pathSuffix) == pathSuffix, "unexpected task path: " .. call.path)
  assertTable(call.arguments, expectedArguments, "task arguments")
end

assertEqual((function() local count = 0; for _ in pairs(bindings) do count = count + 1 end; return count end)(), 8, "binding count")

local id = press({ "cmd", "ctrl" }, "t")
assertTask(id, "/opt/homebrew/bin/mimi", {
  "action", "resize_window", "--width-percent", "100", "--height-percent", "50", "--anchor", "bl",
})
collectgarbage("collect")
assert(taskReferences[id] ~= nil, "running task must be retained")
complete(id, 0, "ignored stdout", "ignored stderr")
collectgarbage("collect")
assert(taskReferences[id] == nil, "completed task must be released")

id = press({ "cmd", "ctrl" }, "t")
assertTask(id, "/opt/homebrew/bin/mimi", {
  "action", "resize_window", "--width-percent", "100", "--height-percent", "33.333333", "--anchor", "bl",
})
complete(id, 0)
id = press({ "cmd", "ctrl" }, "t")
assertTask(id, "/opt/homebrew/bin/mimi", {
  "action", "resize_window", "--width-percent", "100", "--height-percent", "66.666667", "--anchor", "bl",
})
complete(id, 0)
id = press({ "cmd", "ctrl" }, "t")
assertTask(id, "/opt/homebrew/bin/mimi", {
  "action", "resize_window", "--width-percent", "100", "--height-percent", "50", "--anchor", "bl",
})
complete(id, 0)

for key, expected in pairs({
  c = { "50", "100", "cc" },
  g = { "50", "100", "tl" },
  r = { "50", "100", "tr" },
  n = { "100", "50", "tl" },
}) do
  id = press({ "cmd", "ctrl" }, key)
  assertTask(id, "/opt/homebrew/bin/mimi", {
    "action", "resize_window", "--width-percent", expected[1], "--height-percent", expected[2], "--anchor", expected[3],
  })
  complete(id, 0)
end

id = press({ "cmd", "ctrl" }, "f")
assertTask(id, "/opt/homebrew/bin/mimi", {
  "action", "resize_window", "--width-percent", "100", "--height-percent", "100", "--anchor", "tl",
})
complete(id, 0)
id = press({ "cmd", "ctrl" }, "t")
assertTask(id, "/opt/homebrew/bin/mimi", {
  "action", "resize_window", "--width-percent", "100", "--height-percent", "50", "--anchor", "bl",
})
complete(id, 0)

id = press({ "cmd", "alt", "shift" }, "f")
assertTask(id, "/usr/bin/osascript", { raycastRoot .. "/two-panes-finder.applescript" })
complete(id, 0)
id = press({ "cmd", "alt", "shift" }, "c")
assertTask(id, "/bin/bash", { raycastRoot .. "/title-case-chicago.sh" })
complete(id, 0)

local function assertFailure(newMode, startMode)
  taskMode.new = newMode
  taskMode.start = startMode
  local priorAlerts = #alerts
  local priorTasks = taskSequence
  local failedId = press({ "cmd", "alt", "shift" }, "c")
  assertEqual(#alerts, priorAlerts + 1, "failure alert count")
  assertEqual(taskSequence, priorTasks + (newMode == nil and 1 or 0), "failure task count")
  assert(not alerts[#alerts]:find("SECRET", 1, true), "failure alert leaked task output")
  if failedId == priorTasks then return end
  taskCallbacks[failedId] = nil
  taskReferences[failedId] = nil
end

assertFailure("nil", nil)
assertFailure("error", nil)
assertFailure(nil, "false")
assertFailure(nil, "error")
taskMode.new = nil
taskMode.start = nil

local priorAlerts = #alerts
id = press({ "cmd", "alt", "shift" }, "c")
complete(id, 7, "SECRET stdout", "SECRET stderr")
assertEqual(#alerts, priorAlerts + 1, "callback failure alert count")
assert(not alerts[#alerts]:find("SECRET", 1, true), "callback leaked task output")

print("utility_command_test: ok")
