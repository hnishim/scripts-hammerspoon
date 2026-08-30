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
local moveScreenFailure = nil
local readbackFailure = nil
local windowCalls = 0
local readbackCalls = 0
local moveCalls = {}
local screenFrame = { x = 100, y = 200, w = 1200, h = 900 }
local currentFrame = { x = 100, y = 200, w = 1200, h = 900 }
local screenIndex = 1
local screenCount = 3
local screenSpecs = {
  { id = "A", frame = { x = 100, y = 200, w = 1200, h = 900 } },
  { id = "B", frame = { x = 1300, y = 200, w = 1200, h = 900 } },
  { id = "C", frame = { x = 2500, y = 200, w = 1200, h = 900 } },
}
local readbackFrames = nil
local readbackMode = nil
local setFrames = {}
local successMessage = "ウィンドウのサイズ変更に成功しました。"
local raycastRoot = (os.getenv("HOME") or "") .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast"
local finderExecutable = "/usr/bin/osascript"
local finderScript = raycastRoot .. "/two-panes-finder.applescript"
local titleCaseExecutable = "/bin/bash"
local titleCaseScript = raycastRoot .. "/title-case-chicago.sh"

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

local function currentScreen()
  local spec = screenSpecs[screenIndex]
  return {
    id = spec.id,
    frame = function()
      if screenFrameFailure == "error" then error("screen frame failure") end
      if screenFrameFailure == "nil" then return nil end
      return frameCopy(screenIndex == 1 and screenFrame or spec.frame)
    end,
    previous = function()
      local previousIndex = screenIndex == 1 and screenCount or screenIndex - 1
      return {
        id = screenSpecs[previousIndex].id,
        index = previousIndex,
        frame = function() return frameCopy(screenSpecs[previousIndex].frame) end,
      }
    end,
    index = screenIndex,
  }
end

local function configureScreens(count)
  screenCount = count
  screenIndex = 1
  screenFrame = frameCopy(screenSpecs[1].frame)
  currentFrame = frameCopy(screenFrame)
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
      local screen = currentScreen()
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
        moveToScreen = function(_, target, noResize, ensureInScreenBounds, duration)
          assert(not moveScreenFailure, "moveToScreen failure")
          moveCalls[#moveCalls + 1] = {
            target = target,
            noResize = noResize,
            ensureInScreenBounds = ensureInScreenBounds,
            duration = duration,
          }
          screenIndex = target.index
          screenFrame = frameCopy(screenSpecs[screenIndex].frame)
          if ensureInScreenBounds then
            currentFrame.x = math.max(screenFrame.x, math.min(currentFrame.x, screenFrame.x + screenFrame.w - currentFrame.w))
            currentFrame.y = math.max(screenFrame.y, math.min(currentFrame.y, screenFrame.y + screenFrame.h - currentFrame.h))
          end
        end,
      }
    end,
  },
  screen = {
    allScreens = function()
      local screens = {}
      for index = 1, screenCount do
        local spec = screenSpecs[index]
        screens[index] = { id = spec.id, index = index, frame = function() return frameCopy(spec.frame) end }
      end
      return screens
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
local utilityCommand = require("actions.utility_command")
local windowManagement = require("actions.window_management")

local function press(modifiers, key)
  if table.concat(modifiers, "+") == "cmd+ctrl" then
    local names = { t = "bottom", c = "center", g = "left", f = "full", r = "right", n = "top", p = "previous-display" }
    return windowManagement.run(names[key] or key)
  end
  local commands = { f = { finderExecutable, finderScript }, c = { titleCaseExecutable, titleCaseScript } }
  local command = commands[key]
  return utilityCommand.run(command and command[1], command and command[2])
end

local function complete(id, exitCode, stdout, stderr)
  local callback = taskCallbacks[id]
  assert(callback, "missing task callback " .. tostring(id))
  callback(exitCode, stdout, stderr)
  taskCallbacks[id] = nil
end

local function assertTask(id, executablePath, expectedArguments)
  local call = taskCalls[id]
  assert(call, "missing task call " .. tostring(id))
  assertEqual(call.path, executablePath, "unexpected task executable path")
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

local function assertNoActionResidue(message)
  assertEqual(activeTimerCount(), 0, message .. " timer count")
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

-- Display movement uses Previous in a two-screen cycle and remains valid for
-- larger configurations. The mock clamps the resulting frame to verify the
-- ensureInScreenBounds contract without relying on a real Hammerspoon window.
local function assertContained(frame, screen, message)
  assert(frame.x >= screen.x and frame.y >= screen.y, message .. " origin")
  assert(frame.x + frame.w <= screen.x + screen.w, message .. " right edge")
  assert(frame.y + frame.h <= screen.y + screen.h, message .. " bottom edge")
end

configureScreens(2)
local priorMoves = #moveCalls
press({ "cmd", "ctrl" }, "p")
assertEqual(#moveCalls, priorMoves + 1, "two-screen A to B moves once")
local move = moveCalls[#moveCalls]
assertEqual(move.target.id, "B", "two-screen A previous target")
assertEqual(move.noResize, false, "moveToScreen noResize")
assertEqual(move.ensureInScreenBounds, true, "moveToScreen ensureInScreenBounds")
assertEqual(move.duration, 0, "moveToScreen duration")
assertContained(currentFrame, screenSpecs[2].frame, "A to B frame is contained")
press({ "cmd", "ctrl" }, "p")
assertEqual(moveCalls[#moveCalls].target.id, "A", "two-screen B previous target")
assertContained(currentFrame, screenSpecs[1].frame, "B to A frame is contained")

configureScreens(3)
press({ "cmd", "ctrl" }, "p")
assertEqual(moveCalls[#moveCalls].target.id, "C", "three-screen A previous target")
press({ "cmd", "ctrl" }, "p")
assertEqual(moveCalls[#moveCalls].target.id, "B", "three-screen C previous target")
press({ "cmd", "ctrl" }, "p")
assertEqual(moveCalls[#moveCalls].target.id, "A", "three-screen B previous target")

configureScreens(1)
local priorOneScreenMoves, priorOneScreenAlerts = #moveCalls, #alerts
local oneScreenOK = pcall(function() press({ "cmd", "ctrl" }, "p") end)
assertEqual(oneScreenOK, true, "one-screen movement does not throw")
assertEqual(#moveCalls, priorOneScreenMoves, "one-screen movement is a no-op")
assertEqual(#alerts, priorOneScreenAlerts, "one-screen movement has no notification")

configureScreens(2)
moveScreenFailure = true
local priorMoveFailureAlerts, priorMoveFailureMoves = #alerts, #moveCalls
local moveFailureOK = pcall(function() press({ "cmd", "ctrl" }, "p") end)
moveScreenFailure = nil
assertEqual(moveFailureOK, true, "move failure is contained")
assertEqual(#moveCalls, priorMoveFailureMoves, "failed move is not recorded as successful")
assertFailureAlert(priorMoveFailureAlerts, "moveToScreen failure notification")
press({ "cmd", "ctrl" }, "p")
assertEqual(#moveCalls, priorMoveFailureMoves + 1, "movement continues after move failure")

-- Moving displays cancels a pending layout readback and invalidates its stale callback.
setReadbackOffset("x", 3)
press({ "cmd", "ctrl" }, "t")
local staleMoveTimer = latestTimer
local priorMoveStaleAlerts = #alerts
press({ "cmd", "ctrl" }, "p")
assert(staleMoveTimer.stopped, "display movement stops prior readback timer")
assertEqual(activeTimerCount(), 0, "display movement leaves no pending readback")
staleMoveTimer.callback()
assertEqual(#alerts, priorMoveStaleAlerts, "stale display-movement callback cannot alert")

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
windowManagement.stop()
utilityCommand.stop()
assert(staleStopTimer.stopped, "stop cancels pending readback timer")
assert(timerStops > stopsBeforeStop, "stop invokes timer cancellation")
assertNoActionResidue("stop cleanup")
staleStopTimer.callback()
assertEqual(#alerts, priorStopAlerts, "stale stop callback cannot alert")

-- Named actions are checked after geometry/cycle assertions so the probes do not
-- alter the state used by the physical-key-equivalent checks above.
assertNoAlert(function() assertEqual(windowManagement.run("bottom") ~= false, true, "bottom action name is accepted") end,
  "bottom action name")
assertNoAlert(function() assertEqual(windowManagement.run("center") ~= false, true, "center action name is accepted") end,
  "center action name")
assertNoAlert(function() assertEqual(windowManagement.run("left") ~= false, true, "left action name is accepted") end,
  "left action name")
assertNoAlert(function() assertEqual(windowManagement.run("full") ~= false, true, "full action name is accepted") end,
  "full action name")
assertNoAlert(function() assertEqual(windowManagement.run("right") ~= false, true, "right action name is accepted") end,
  "right action name")
assertNoAlert(function() assertEqual(windowManagement.run("top") ~= false, true, "top action name is accepted") end,
  "top action name")
assertEqual(windowManagement.run("invalid"), false, "invalid window action is rejected")
windowManagement.stop()

-- Registration lifecycle is owned by hotkeys_test.lua; this test covers only
-- action behavior and task cleanup.
utilityCommand.stop()
assertNoActionResidue("action cleanup")

-- Finder and Title Case task callbacks retain completion/failure handling and do not leak output.
local function assertTaskCompletion(label, executablePath, scriptPath, exitCode)
  local id = taskSequence + 1
  local priorAlerts = #alerts
  utilityCommand.run(executablePath, scriptPath)
  assertTask(id, executablePath, { scriptPath })
  collectgarbage("collect")
  assert(taskReferences[id] ~= nil, label .. " running task must be retained")
  complete(id, exitCode, "SECRET stdout", "SECRET stderr")
  assert(taskCallbacks[id] == nil, label .. " callback released after completion")
  collectgarbage("collect")
  assert(taskReferences[id] == nil, label .. " task released after completion")
  if exitCode == 0 then
    assertEqual(#alerts, priorAlerts, label .. " success has no notification")
  else
    assertFailureAlert(priorAlerts, label .. " failure notification")
    assert(not alerts[#alerts].message:find("SECRET", 1, true), label .. " completion leaked task output")
  end
end

assertTaskCompletion("finder success", finderExecutable, finderScript, 0)
assertTaskCompletion("finder failure", finderExecutable, finderScript, 7)
assertTaskCompletion("title case success", titleCaseExecutable, titleCaseScript, 0)
assertTaskCompletion("title case failure", titleCaseExecutable, titleCaseScript, 7)

local beforeMissingScript = taskSequence
utilityCommand.run(titleCaseExecutable, raycastRoot .. "/missing-title-case-chicago.sh")
assertEqual(taskSequence, beforeMissingScript, "missing script does not create a task")

local beforeMissingExecutable = taskSequence
utilityCommand.run("/missing/raycast-executable", titleCaseScript)
assertEqual(taskSequence, beforeMissingExecutable, "missing executable does not create a task")

local function assertInvalidCommand(label, executablePath, scriptPath)
  local beforeTasks = taskNewCalls
  utilityCommand.run(executablePath, scriptPath)
  assertEqual(taskNewCalls, beforeTasks, label .. " does not create a task")
end
for _, testCase in ipairs({
  { label = "nil executable", value = nil },
  { label = "empty executable", value = "" },
  { label = "non-string executable", value = 42 },
}) do
  assertInvalidCommand(testCase.label, testCase.value, titleCaseScript)
end
for _, testCase in ipairs({
  { label = "nil script", value = nil },
  { label = "empty script", value = "" },
  { label = "non-string script", value = 42 },
}) do
  assertInvalidCommand(testCase.label, titleCaseExecutable, testCase.value)
end

local function assertTaskSetupFailure(newMode, startMode, label)
  taskMode.new, taskMode.start = newMode, startMode
  local priorAlerts, priorTasks = #alerts, taskSequence
  local priorCallbacks, priorReferences = entryCount(taskCallbacks), entryCount(taskReferences)
  utilityCommand.run(titleCaseExecutable, titleCaseScript)
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
