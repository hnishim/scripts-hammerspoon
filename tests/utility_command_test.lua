local bindings = {}
local bindingHandles = {}
local deletedHandles = {}
local bindFailureKey = nil
local taskCallbacks = setmetatable({}, { __mode = "v" })
local taskReferences = setmetatable({}, { __mode = "v" })
local taskCalls = {}
local taskNewCalls = 0
local alerts = {}
local taskMode = { new = nil, start = nil }
local taskSequence = 0
local timerSequence = 0
local timers = {}
local timerStops = 0
local latestTimer = nil
local frontmostMode = nil
local screenMethodFailure = nil
local screenFrameFailure = nil
local setFrameFailure = nil
local readbackFailure = nil
local windowCalls = 0
local readbackCalls = 0
local screenFrame = { x = 100, y = 200, w = 1200, h = 900 }
local currentFrame = { x = 100, y = 200, w = 1200, h = 900 }
local readbackFrames = nil
local readbackMode = nil
local setFrames = {}
local successMessage = "ウィンドウのサイズ変更に成功しました。"
local raycastRoot = (os.getenv("HOME") or "") .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast"

local function signature(modifiers, key)
  return table.concat(modifiers, "+") .. ":" .. key
end

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertNear(actual, expected, message)
  assert(math.abs(actual - expected) <= 2, string.format("%s: expected %s +/- 2, got %s", message, tostring(expected), tostring(actual)))
end

local function assertExactFrame(actual, expected, message)
  for _, field in ipairs({ "x", "y", "w", "h" }) do assertEqual(actual[field], expected[field], message .. "." .. field) end
end

local function assertTolerantFrame(actual, expected, message)
  for _, field in ipairs({ "x", "y", "w", "h" }) do assertNear(actual[field], expected[field], message .. "." .. field) end
end

local function assertTable(actual, expected, message)
  assertEqual(#actual, #expected, message .. " length")
  for index, value in ipairs(expected) do assertEqual(actual[index], value, message .. "[" .. index .. "]") end
end

local function handleCount()
  local count = 0
  for _ in pairs(bindingHandles) do count = count + 1 end
  return count
end

local function activeTimerCount()
  local count = 0
  for _, timer in pairs(timers) do
    if not timer.stopped and not timer.fired then count = count + 1 end
  end
  return count
end

local function fireTimer(timer)
  assert(timer and not timer.fired, "missing timer to fire")
  for id, candidate in pairs(timers) do
    if candidate == timer then timers[id] = nil; break end
  end
  timer.fired = true
  timer.callback()
end

local function setReadback(sequence)
  readbackFrames, readbackMode, readbackCalls = sequence, nil, 0
end

local function setReadbackOffset(field, delta)
  readbackFrames, readbackMode, readbackCalls = nil, { field = field, delta = delta }, 0
end

local function frameCopy(frame)
  return { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
end

local function frameFromWindow()
  readbackCalls = readbackCalls + 1
  if readbackFailure == "error" then error("frame readback failure") end
  if readbackFailure == "nil" then return nil end
  if readbackMode then
    local frame = frameCopy(currentFrame)
    frame[readbackMode.field] = frame[readbackMode.field] + readbackMode.delta
    return frame
  end
  if readbackFrames and #readbackFrames > 0 then
    local frame = table.remove(readbackFrames, 1)
    if frame == "error" then error("frame readback failure") end
    if frame == "current" then return currentFrame end
    if frame == "boundary" then return { x = currentFrame.x + 2, y = currentFrame.y, w = currentFrame.w, h = currentFrame.h } end
    return frame
  end
  return currentFrame
end

_G.hs = {
  alert = {
    show = function(message, duration)
      alerts[#alerts + 1] = {
        message = message,
        duration = duration,
        kind = message == successMessage and "success" or "failure",
      }
    end,
  },
  hotkey = {
    bind = function(modifiers, key, callback)
      local name = signature(modifiers, key)
      if name == bindFailureKey then error("hotkey bind failure") end
      local handle = {
        name = name,
        delete = function(self)
          if self.deleted then return end
          self.deleted = true
          if bindingHandles[self.name] == self then bindingHandles[self.name] = nil end
          if bindings[self.name] == callback then bindings[self.name] = nil end
          deletedHandles[#deletedHandles + 1] = self
        end,
      }
      bindingHandles[name] = handle
      bindings[name] = callback
      return handle
    end,
  },
  timer = {
    doAfter = function(delay, callback)
      timerSequence = timerSequence + 1
      local id = timerSequence
      local timer = { delay = delay, callback = callback, stopped = false, fired = false }
      function timer:stop() self.stopped = true; timerStops = timerStops + 1 end
      timers[id] = timer
      latestTimer = timer
      return timer
    end,
    stop = function(timer) timer:stop() end,
  },
  window = {
    frontmostWindow = function()
      windowCalls = windowCalls + 1
      if frontmostMode == "error" then error("window lookup failure") end
      if frontmostMode == "nil" then return nil end
      local screen = {
        frame = function()
          if screenFrameFailure == "error" then error("screen frame failure") end
          if screenFrameFailure == "nil" then return nil end
          return frameCopy(screenFrame)
        end,
      }
      return {
        screen = function()
          if screenMethodFailure == "error" then error("window screen failure") end
          if screenMethodFailure == "nil" then return nil end
          return screen
        end,
        frame = function() return frameFromWindow() end,
        setFrame = function(_, frame, duration)
          assertEqual(duration, 0, "setFrame duration")
          if setFrameFailure then error("setFrame failure") end
          setFrames[#setFrames + 1] = frameCopy(frame)
          currentFrame = frameCopy(frame)
        end,
      }
    end,
  },
  task = {
    new = function(path, callback, arguments)
      taskNewCalls = taskNewCalls + 1
      if taskMode.new == "nil" then return nil end
      if taskMode.new == "error" then error("task creation failure") end
      taskSequence = taskSequence + 1
      local id = taskSequence
      local task = {
        start = function()
          if taskMode.start == "error" then
            error("task start failure")
          end
          if taskMode.start == "false" then
            return false
          end
          return true
        end,
        callback = callback,
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

local function press(modifiers, key)
  local name = signature(modifiers, key)
  local handle = bindingHandles[name]
  assert(handle and not handle.deleted, "missing live binding " .. name)
  local callback = bindings[name]
  assert(callback, "missing binding " .. signature(modifiers, key))
  callback()
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

local function expectedFrame(widthPercent, heightPercent, anchor)
  local screen = screenFrame
  -- Requested frames use nearest-integer rounding for dimensions and edges.
  local function round(value) return math.floor(value + 0.5) end
  local w, h = round(screen.w * widthPercent), round(screen.h * heightPercent)
  local left, top = round(screen.x), round(screen.y)
  local right, bottom = round(screen.x + screen.w), round(screen.y + screen.h)
  local x, y = left, top
  if anchor == "bl" then y = bottom - h
  elseif anchor == "cc" then x = round((left + right - w) / 2); y = round((top + bottom - h) / 2)
  elseif anchor == "tr" then x = right - w
  end
  return { x = x, y = y, w = w, h = h }
end

local function assertLayout(key, width, height, anchor)
  local before = #setFrames
  local beforeTasks, beforeWindows = taskNewCalls, windowCalls
  press({ "cmd", "ctrl" }, key)
  assertEqual(#setFrames, before + 1, key .. " setFrame count")
  assertEqual(taskNewCalls, beforeTasks, key .. " does not invoke hs.task.new")
  assertEqual(windowCalls, beforeWindows + 1, key .. " uses hs.window path")
  assertExactFrame(setFrames[#setFrames], expectedFrame(width, height, anchor), key .. " exact target")
end

local function assertNoAlert(action, message)
  local count = #alerts
  action()
  assertEqual(#alerts, count, message)
end

local function assertFailureAlert(priorAlerts, message)
  assertEqual(#alerts, priorAlerts + 1, message .. " count")
  local alert = alerts[#alerts]
  assertEqual(alert.kind, "failure", message .. " kind")
  assert(alert.message ~= successMessage, message .. " used success message")
end

local function assertNoBindings(message)
  assertEqual(handleCount(), 0, message .. " handle count")
  assertEqual(activeTimerCount(), 0, message .. " timer count")
  for _, key in ipairs({ "t", "c", "g", "r", "n", "f" }) do
    local name = signature({ "cmd", "ctrl" }, key)
    assert(bindingHandles[name] == nil, message .. " residual handle " .. name)
    assert(bindings[name] == nil, message .. " residual callback " .. name)
    local pressed = pcall(function() press({ "cmd", "ctrl" }, key) end)
    assert(not pressed, message .. " deleted binding executed " .. name)
  end
  for _, key in ipairs({ "f", "c" }) do
    local name = signature({ "cmd", "alt", "shift" }, key)
    assert(bindingHandles[name] == nil, message .. " residual handle " .. name)
    assert(bindings[name] == nil, message .. " residual callback " .. name)
    local pressed = pcall(function() press({ "cmd", "alt", "shift" }, key) end)
    assert(not pressed, message .. " deleted binding executed " .. name)
  end
end

local function entryCount(tableValue)
  local count = 0
  for _ in pairs(tableValue) do count = count + 1 end
  return count
end

local function assertNoTaskResidue(callbackCount, referenceCount, message)
  collectgarbage("collect")
  assertEqual(entryCount(taskCallbacks), callbackCount, message .. " callback cleanup")
  assertEqual(entryCount(taskReferences), referenceCount, message .. " task reference cleanup")
end

local function assertReadbackTolerance(field, delta)
  setReadbackOffset(field, delta)
  local priorAlerts = #alerts
  press({ "cmd", "ctrl" }, "t")
  assertEqual(readbackCalls, 1, field .. " " .. delta .. "px uses immediate readback")
  assertEqual(#alerts, priorAlerts, field .. " " .. delta .. "px succeeds")
  assertEqual(activeTimerCount(), 0, field .. " " .. delta .. "px leaves no timer")
end

local function assertReadbackThreePixelFailure(field, delta)
  setReadbackOffset(field, delta)
  local priorAlerts = #alerts
  press({ "cmd", "ctrl" }, "t")
  local label = field .. " " .. delta .. "px"
  assertEqual(readbackCalls, 1, label .. " first attempt")
  local secondAttempt = latestTimer
  assertEqual(secondAttempt.delay, 0.05, label .. " second-attempt delay")
  fireTimer(secondAttempt)
  assertEqual(readbackCalls, 2, label .. " second attempt")
  local thirdAttempt = latestTimer
  assertEqual(thirdAttempt.delay, 0.1, label .. " third-attempt delay")
  fireTimer(thirdAttempt)
  assertEqual(readbackCalls, 3, label .. " third attempt")
  assertEqual(activeTimerCount(), 0, label .. " leaves no timer")
  assertFailureAlert(priorAlerts, label .. " failure notification")
end

local function assertWindowFailure(failureName, setFailure, failureValue)
  setReadback(nil)
  local priorAlerts, priorFrames, priorTasks = #alerts, #setFrames, taskNewCalls
  setFailure(failureValue or "error")
  press({ "cmd", "ctrl" }, "t")
  setFailure(nil)
  assertFailureAlert(priorAlerts, failureName .. " notification")
  assertEqual(#setFrames, priorFrames, failureName .. " does not set a frame")
  assertEqual(taskNewCalls, priorTasks, failureName .. " does not invoke hs.task.new")
  assertEqual(activeTimerCount(), 0, failureName .. " leaves no timer")
end

utilityCommand.start()
assertEqual(handleCount(), 8, "initial registry contains all eight handles")

-- Public layout mapping, exact requested geometry, direction cycles, maximize reset, and dynamic frames.
assertLayout("t", 1, 0.5, "bl")
assertLayout("t", 1, 1 / 3, "bl")
assertLayout("t", 1, 2 / 3, "bl")
assertLayout("c", 0.5, 1, "cc")
assertLayout("c", 1 / 3, 1, "cc")
assertLayout("c", 2 / 3, 1, "cc")
assertLayout("g", 0.5, 1, "tl")
assertLayout("g", 1 / 3, 1, "tl")
assertLayout("g", 2 / 3, 1, "tl")
assertLayout("r", 0.5, 1, "tr")
assertLayout("r", 1 / 3, 1, "tr")
assertLayout("r", 2 / 3, 1, "tr")
assertLayout("n", 1, 0.5, "tl")
assertLayout("n", 1, 1 / 3, "tl")
assertLayout("n", 1, 2 / 3, "tl")
local beforeMaximizeTasks, beforeMaximizeWindows = taskNewCalls, windowCalls
press({ "cmd", "ctrl" }, "f")
assertEqual(taskNewCalls, beforeMaximizeTasks, "maximize does not invoke hs.task.new")
assertEqual(windowCalls, beforeMaximizeWindows + 1, "maximize uses hs.window path")
assertExactFrame(setFrames[#setFrames], expectedFrame(1, 1, "tl"), "maximize exact target")
assertLayout("t", 1, 0.5, "bl")
screenFrame = { x = 10.25, y = 20.75, w = 1001.5, h = 777.25 }
assertLayout("r", 0.5, 1, "tr")
assertExactFrame(setFrames[#setFrames], expectedFrame(0.5, 1, "tr"), "non-integer screen rounded target")

-- Readback tolerance is independent from exact setFrame target equality.
setReadback(nil)
assertNoAlert(function() press({ "cmd", "ctrl" }, "t") end, "immediate readback success")
assertEqual(readbackCalls, 1, "immediate readback attempt count")
setReadback({ { x = 0, y = 0, w = 1, h = 1 }, "current" })
press({ "cmd", "ctrl" }, "t")
assertEqual(readbackCalls, 1, "later readback immediate attempt count")
local laterTimer = latestTimer
assertEqual(laterTimer.delay, 0.05, "later readback delay")
fireTimer(laterTimer)
assertEqual(readbackCalls, 2, "later readback second attempt count")
assertEqual(#alerts, 0, "later readback success has no alert")
assertEqual(activeTimerCount(), 0, "later readback leaves no timer")
for _, field in ipairs({ "x", "y", "w", "h" }) do
  assertReadbackTolerance(field, 2)
  assertReadbackTolerance(field, -2)
end
for _, field in ipairs({ "x", "y", "w", "h" }) do
  assertReadbackThreePixelFailure(field, 3)
  assertReadbackThreePixelFailure(field, -3)
end

-- Window, screen, setFrame, and readback failure paths are deterministic.
assertWindowFailure("frontmostWindow nil", function(value) frontmostMode = value end, "nil")
assertWindowFailure("frontmostWindow error", function(value) frontmostMode = value end, "error")
assertWindowFailure("window:screen nil", function(value) screenMethodFailure = value end, "nil")
assertWindowFailure("window:screen exception", function(value) screenMethodFailure = value end, "error")
assertWindowFailure("screen:frame nil", function(value) screenFrameFailure = value end, "nil")
assertWindowFailure("screen:frame exception", function(value) screenFrameFailure = value end, "error")
assertWindowFailure("window:setFrame exception", function(value) setFrameFailure = value end, "error")
local function assertReadbackFailure(failureValue, failureName)
  setReadback(nil)
  readbackFailure = failureValue
  local priorAlerts = #alerts
  press({ "cmd", "ctrl" }, "t")
  while activeTimerCount() > 0 do fireTimer(latestTimer) end
  readbackFailure = nil
  assertFailureAlert(priorAlerts, failureName .. " notification")
  assert(readbackCalls >= 1 and readbackCalls <= 3, failureName .. " attempts are capped at three")
  assertEqual(activeTimerCount(), 0, failureName .. " leaves no timer")
end
assertReadbackFailure("nil", "window:frame nil")
assertReadbackFailure("error", "window:frame exception")

-- New resize and stop cancel pending timers; stale callbacks cannot report.
setReadbackOffset("x", 3)
press({ "cmd", "ctrl" }, "t")
local staleResizeTimer = latestTimer
local priorStaleAlerts = #alerts
setReadback(nil)
press({ "cmd", "ctrl" }, "c")
assert(staleResizeTimer.stopped, "new resize stops prior readback timer")
assertEqual(activeTimerCount(), 0, "new resize leaves no pending timer after immediate success")
staleResizeTimer.callback()
assertEqual(#alerts, priorStaleAlerts, "stale resize callback cannot alert")
setReadbackOffset("y", 3)
press({ "cmd", "ctrl" }, "t")
local staleStopTimer = latestTimer
local priorStopAlerts = #alerts
local stopsBeforeStop = timerStops
utilityCommand.stop()
utilityCommand.stop()
assert(staleStopTimer.stopped, "stop cancels pending readback timer")
assert(timerStops > stopsBeforeStop, "stop invokes timer cancellation")
assertNoBindings("stop cleanup")
staleStopTimer.callback()
assertEqual(#alerts, priorStopAlerts, "stale stop callback cannot alert")

-- start -> start replaces handles; stop is idempotent; bind failure rolls back without throwing.
utilityCommand.start()
local deletedBeforeRestart = #deletedHandles
utilityCommand.start()
assertEqual(handleCount(), 8, "restart leaves eight handles")
assertEqual(#deletedHandles, deletedBeforeRestart + 8, "restart deletes prior eight handles")
utilityCommand.stop()
assertNoBindings("first stop")
local deletedAfterStop = #deletedHandles
utilityCommand.stop()
assertEqual(#deletedHandles, deletedAfterStop, "second stop is idempotent")
bindFailureKey = "cmd+ctrl:g"
local priorBindFailureAlerts = #alerts
local startedOK, startResult = pcall(utilityCommand.start)
if startedOK then
  assert(startResult == false or #alerts > priorBindFailureAlerts, "start failure has approved return or notification")
  if #alerts > priorBindFailureAlerts then assertFailureAlert(priorBindFailureAlerts, "start failure notification") end
end
assertNoBindings("mid-bind rollback")
bindFailureKey = nil
utilityCommand.start()
assertEqual(handleCount(), 8, "start remains reload-safe after rollback")

-- Finder and Title Case task callbacks retain completion/failure handling and do not leak output.
local function assertTaskCompletion(key, pathSuffix, expectedArguments, exitCode)
  local id = taskSequence + 1
  local priorAlerts = #alerts
  press({ "cmd", "alt", "shift" }, key)
  assertTask(id, pathSuffix, expectedArguments)
  collectgarbage("collect")
  assert(taskReferences[id] ~= nil, key .. " running task must be retained")
  complete(id, exitCode, "SECRET stdout", "SECRET stderr")
  assert(taskCallbacks[id] == nil, key .. " callback released after completion")
  collectgarbage("collect")
  assert(taskReferences[id] == nil, key .. " task released after completion")
  if exitCode == 0 then
    assertEqual(#alerts, priorAlerts, key .. " success has no notification")
  else
    assertFailureAlert(priorAlerts, key .. " failure notification")
    assert(not alerts[#alerts].message:find("SECRET", 1, true), key .. " completion leaked task output")
  end
end

assertTaskCompletion("f", "/usr/bin/osascript", { raycastRoot .. "/two-panes-finder.applescript" }, 0)
assertTaskCompletion("f", "/usr/bin/osascript", { raycastRoot .. "/two-panes-finder.applescript" }, 7)
assertTaskCompletion("c", "/bin/bash", { raycastRoot .. "/title-case-chicago.sh" }, 0)
assertTaskCompletion("c", "/bin/bash", { raycastRoot .. "/title-case-chicago.sh" }, 7)

local function assertTaskSetupFailure(newMode, startMode, label)
  taskMode.new, taskMode.start = newMode, startMode
  local priorAlerts, priorTasks = #alerts, taskSequence
  local priorCallbacks, priorReferences = entryCount(taskCallbacks), entryCount(taskReferences)
  press({ "cmd", "alt", "shift" }, "c")
  assertFailureAlert(priorAlerts, label .. " notification")
  assert(not alerts[#alerts].message:find("SECRET", 1, true), label .. " leaked task output")
  assertEqual(taskSequence, priorTasks + (newMode == nil and 1 or 0), label .. " task sequence")
  assertNoTaskResidue(priorCallbacks, priorReferences, label)
  taskMode.new, taskMode.start = nil, nil
end

assertTaskSetupFailure("nil", nil, "task creation nil")
assertTaskSetupFailure("error", nil, "task creation exception")
assertTaskSetupFailure(nil, "false", "task start false")
assertTaskSetupFailure(nil, "error", "task start exception")

print("utility_command_test: ok")
