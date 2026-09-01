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
local initialWindowFrameFailure = nil
local initialWindowFrameValue = nil
local initialWindowFrameCalls = 0
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
local setFrameAttempts = 0
local layoutEvents = {}
local minimumSizeCorrection = nil
local correctionWasApplied = false
local correctiveSetFrameFailure = nil
local finalReadbackMode = nil
local finalReadbackFrames = nil
local finalReadbackActive = false
local successMessage = "ウィンドウのサイズ変更に成功しました。"
local raycastRoot = (os.getenv("HOME") or "") .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast"
local finderExecutable = "/usr/bin/osascript"
local finderScript = raycastRoot .. "/two-panes-finder.applescript"
local titleCaseExecutable = "/bin/bash"
local titleCaseScript = raycastRoot .. "/title-case-chicago.sh"
local titleCasePythonScript = raycastRoot .. "/title-case-chicago.py"

local realIoOpen = io.open
local function readRealFile(path)
  local handle = realIoOpen(path, "r")
  assert(handle, "expected readable file: " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

local titleCaseShellContents = readRealFile(titleCaseScript)
assert(titleCasePythonScript:match("^(.+)/[^/]+$") == titleCaseScript:match("^(.+)/[^/]+$"),
  "Title Case shell and Python scripts must share a directory")
assert(titleCaseShellContents:find("SCRIPT_DIR/title-case-chicago.py", 1, true),
  "Title Case shell script must pass SCRIPT_DIR/title-case-chicago.py to Python")

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

local function recordReadback(frame)
  layoutEvents[#layoutEvents + 1] = { kind = "readback", frame = frameCopy(frame) }
  return frame
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

local function frameFromWindow(isInitialLookup)
  if isInitialLookup then
    initialWindowFrameCalls = initialWindowFrameCalls + 1
  else
    readbackCalls = readbackCalls + 1
  end
  if isInitialLookup and initialWindowFrameFailure then
    local failure = initialWindowFrameFailure
    initialWindowFrameFailure = nil
    if failure == "error" then error("window frame failure") end
    return failure == "nil" and nil or frameCopy(failure)
  end
  if isInitialLookup and initialWindowFrameValue then
    local value = initialWindowFrameValue
    initialWindowFrameValue = nil
    return value
  end
  if not isInitialLookup and finalReadbackActive then
    if finalReadbackMode == "error" then error("final frame readback failure") end
    if finalReadbackMode == "nil" then return nil end
    if finalReadbackFrames and #finalReadbackFrames > 0 then
      local frame = table.remove(finalReadbackFrames, 1)
      if frame == "error" then error("final frame readback failure") end
      if frame == "nil" then return nil end
      if frame == "current" then return recordReadback(currentFrame) end
      return recordReadback(frame)
    end
    return recordReadback(currentFrame)
  end
  if not isInitialLookup and readbackFailure == "error" then error("frame readback failure") end
  if not isInitialLookup and readbackFailure == "nil" then return nil end
  if not isInitialLookup and readbackMode then
    local frame = frameCopy(currentFrame)
    frame[readbackMode.field] = frame[readbackMode.field] + readbackMode.delta
    return recordReadback(frame)
  end
  if not isInitialLookup and readbackFrames and #readbackFrames > 0 then
    local frame = table.remove(readbackFrames, 1)
    if frame == "error" then error("frame readback failure") end
    if frame == "current" then return recordReadback(currentFrame) end
    if frame == "boundary" then return recordReadback({ x = currentFrame.x + 2, y = currentFrame.y, w = currentFrame.w, h = currentFrame.h }) end
    return recordReadback(frame)
  end
  return recordReadback(currentFrame)
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
        frame = (function()
          local initialFramePending = true
          return function()
            local isInitialLookup = initialFramePending
            initialFramePending = false
            return frameFromWindow(isInitialLookup)
          end
        end)(),
        setFrame = function(_, frame, duration)
          assertEqual(duration, 0, "setFrame duration")
          setFrameAttempts = setFrameAttempts + 1
          if setFrameFailure then error("setFrame failure") end
          if correctiveSetFrameFailure and correctionWasApplied then error("corrective setFrame failure") end
          local eventRole = correctionWasApplied and "corrective" or (minimumSizeCorrection and "initial" or "normal")
          if minimumSizeCorrection then
            local correction = minimumSizeCorrection
            minimumSizeCorrection = nil
            correctionWasApplied = true
            currentFrame = frameCopy(frame)
            currentFrame.w = correction.w or currentFrame.w
            currentFrame.h = correction.h or currentFrame.h
            currentFrame.x = correction.x or currentFrame.x
            currentFrame.y = correction.y or currentFrame.y
          else
            currentFrame = frameCopy(frame)
            if correctionWasApplied then
              finalReadbackActive = true
              correctionWasApplied = false
            end
          end
          setFrames[#setFrames + 1] = frameCopy(frame)
          layoutEvents[#layoutEvents + 1] = { kind = "setFrame", role = eventRole, frame = frameCopy(frame) }
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

local function expectedVerticalFrame(before, heightPercent, anchor)
  local screen = screenFrame
  local function round(value) return math.floor(value + 0.5) end
  local h = round(screen.h * heightPercent)
  local y = round(screen.y)
  if anchor == "bottom" then y = round(screen.y + screen.h) - h end
  return { x = before.x, y = y, w = before.w, h = h }
end

local function configureMinimumCorrection(correction)
  minimumSizeCorrection = correction
  correctionWasApplied = false
  finalReadbackActive = false
  finalReadbackMode = nil
  finalReadbackFrames = nil
  layoutEvents = {}
  readbackFrames, readbackMode, readbackCalls = nil, nil, 0
end

local function configureFinalReadback(mode, frames)
  finalReadbackMode = mode
  finalReadbackFrames = frames
end

local function clearCorrectionMock()
  minimumSizeCorrection = nil
  correctionWasApplied = false
  correctiveSetFrameFailure = nil
  finalReadbackMode = nil
  finalReadbackFrames = nil
  finalReadbackActive = false
end

local function assertContainedBy(frame, screen, message)
  assert(frame.x >= screen.x and frame.y >= screen.y, message .. " origin")
  assert(frame.x + frame.w <= screen.x + screen.w, message .. " right edge")
  assert(frame.y + frame.h <= screen.y + screen.h, message .. " bottom edge")
end

local function assertStableCorrectionObservation(expectedObserved, message)
  local initialSetIndex
  local correctiveSetIndex
  for index, event in ipairs(layoutEvents) do
    if event.kind == "setFrame" and event.role == "initial" then
      initialSetIndex = index
    elseif event.kind == "setFrame" and event.role == "corrective" then
      correctiveSetIndex = index
      break
    end
  end
  assert(initialSetIndex, message .. " has initial setFrame event")
  assert(correctiveSetIndex, message .. " has corrective setFrame event")
  local previousReadback
  for index = initialSetIndex + 1, correctiveSetIndex - 1 do
    local event = layoutEvents[index]
    if event.kind == "readback" then
      if previousReadback then
        local matches = pcall(assertExactFrame, previousReadback.frame, expectedObserved, message .. " first stable observation")
        local secondMatches = pcall(assertExactFrame, event.frame, expectedObserved, message .. " second stable observation")
        if matches and secondMatches then return end
      end
      previousReadback = event
    end
  end
  error(message .. " does not observe the same corrected frame twice before corrective setFrame")
end

local function assertCorrectedLayout(key, before, correction, expectedObserved, expectedFinal, message)
  currentFrame = frameCopy(before)
  configureMinimumCorrection(correction)
  local priorAlerts, priorFrames = #alerts, #setFrames
  press({ "cmd", "ctrl" }, key)
  while activeTimerCount() > 0 do fireTimer(latestTimer) end
  assertEqual(#alerts, priorAlerts, message .. " has no failure alert")
  assert(#setFrames >= priorFrames + 2, message .. " performs corrective setFrame")
  assertStableCorrectionObservation(expectedObserved, message)
  assertTolerantFrame(setFrames[#setFrames], expectedFinal, message .. " final target")
  assertTolerantFrame(currentFrame, expectedFinal, message .. " final frame")
  assertEqual(activeTimerCount(), 0, message .. " leaves no timer")
  clearCorrectionMock()
end

local function assertVerticalLayout(key, before, heightPercent, anchor)
  currentFrame = frameCopy(before)
  local beforeSetFrames = #setFrames
  press({ "cmd", "ctrl" }, key)
  assertEqual(#setFrames, beforeSetFrames + 1, key .. " vertical setFrame count")
  assertExactFrame(setFrames[#setFrames], expectedVerticalFrame(before, heightPercent, anchor),
    key .. " preserves horizontal frame and uses screen vertical bounds")
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
assertVerticalLayout("t", { x = 180, y = 260, w = 640, h = 420 }, 0.5, "bottom")
assertVerticalLayout("t", { x = 180, y = 260, w = 640, h = 450 }, 2 / 3, "bottom")
assertVerticalLayout("t", { x = 180, y = 260, w = 640, h = 600 }, 0.5, "bottom")
assertLayout("c", 0.5, 1, "cc")
assertLayout("c", 1 / 3, 1, "cc")
assertLayout("c", 2 / 3, 1, "cc")
assertLayout("g", 0.5, 1, "tl")
assertLayout("g", 1 / 3, 1, "tl")
assertLayout("g", 2 / 3, 1, "tl")
assertLayout("r", 0.5, 1, "tr")
assertLayout("r", 1 / 3, 1, "tr")
assertLayout("r", 2 / 3, 1, "tr")
assertVerticalLayout("n", { x = 320, y = 280, w = 700, h = 400 }, 0.5, "top")
assertVerticalLayout("n", { x = 320, y = 280, w = 700, h = 450 }, 2 / 3, "top")
assertVerticalLayout("n", { x = 320, y = 280, w = 700, h = 600 }, 0.5, "top")
local beforeMaximizeTasks, beforeMaximizeWindows = taskNewCalls, windowCalls
press({ "cmd", "ctrl" }, "f")
assertEqual(taskNewCalls, beforeMaximizeTasks, "maximize does not invoke hs.task.new")
assertEqual(windowCalls, beforeMaximizeWindows + 1, "maximize uses hs.window path")
assertExactFrame(setFrames[#setFrames], expectedFrame(1, 1, "tl"), "maximize exact target")
assertVerticalLayout("t", { x = 420, y = 300, w = 500, h = 500 }, 0.5, "bottom")
assertVerticalLayout("t", { x = -700, y = 300, w = 2600, h = 500 }, 2 / 3, "bottom")
press({ "cmd", "ctrl" }, "f")
assertVerticalLayout("t", { x = -700, y = 300, w = 2600, h = 500 }, 0.5, "bottom")
press({ "cmd", "ctrl" }, "f")
assertVerticalLayout("n", { x = -700, y = 300, w = 2600, h = 500 }, 0.5, "top")
screenFrame = { x = 10.25, y = 20.75, w = 1001.5, h = 777.25 }
assertLayout("r", 0.5, 1, "tr")
assertExactFrame(setFrames[#setFrames], expectedFrame(0.5, 1, "tr"), "non-integer screen rounded target")

-- A window may apply a stable minimum-size correction after the requested
-- frame is set. The correction is accepted only after repeated observations,
-- then the requested anchor is recalculated and the corrected frame is set.
screenFrame = { x = 0, y = 30, w = 1440, h = 870 }
currentFrame = { x = 300, y = 100, w = 700, h = 500 }
windowManagement.run("full")
assertCorrectedLayout("n", { x = 300, y = 100, w = 700, h = 500 }, { h = 600 },
  { x = 300, y = 30, w = 700, h = 600 }, { x = 300, y = 30, w = 700, h = 600 },
  "stable top minimum-height correction")
windowManagement.run("full")
assertCorrectedLayout("t", { x = 300, y = 100, w = 700, h = 500 }, { h = 600 },
  { x = 300, y = 465, w = 700, h = 600 }, { x = 300, y = 300, w = 700, h = 600 },
  "stable bottom minimum-height correction")

windowManagement.run("full")
assertCorrectedLayout("g", { x = 300, y = 100, w = 700, h = 500 }, { w = 900 },
  { x = 0, y = 30, w = 900, h = 870 }, { x = 0, y = 30, w = 900, h = 870 },
  "stable left minimum-width correction")
windowManagement.run("full")
assertCorrectedLayout("c", { x = 300, y = 100, w = 700, h = 500 }, { w = 900 },
  { x = 360, y = 30, w = 900, h = 870 }, { x = 270, y = 30, w = 900, h = 870 },
  "stable center minimum-width correction")
windowManagement.run("full")
assertCorrectedLayout("r", { x = 300, y = 100, w = 700, h = 500 }, { w = 900 },
  { x = 720, y = 30, w = 900, h = 870 }, { x = 540, y = 30, w = 900, h = 870 },
  "stable right minimum-width correction")

windowManagement.run("full")
assertCorrectedLayout("r", { x = 300, y = 100, w = 700, h = 500 }, { w = 1000 },
  { x = 720, y = 30, w = 1000, h = 870 }, { x = 440, y = 30, w = 1000, h = 870 },
  "out-of-bounds right correction is re-anchored")
assertContainedBy(currentFrame, screenFrame, "out-of-bounds right correction final frame is contained")

-- A stable correction that cannot fit on the screen remains an explicit
-- failure, while changing observations are not mistaken for a stable clamp.
windowManagement.run("full")
currentFrame = { x = 300, y = 100, w = 700, h = 500 }
configureMinimumCorrection({ h = 1000 })
local impossibleAlerts, impossibleFrames = #alerts, #setFrames
press({ "cmd", "ctrl" }, "t")
while activeTimerCount() > 0 do fireTimer(latestTimer) end
assertFailureAlert(impossibleAlerts, "minimum-height correction larger than screen")
assertEqual(#setFrames, impossibleFrames + 1, "impossible correction does not perform corrective setFrame")
assertEqual(activeTimerCount(), 0, "impossible correction leaves no timer")
clearCorrectionMock()

local function assertInitialCorrectionFailure(message, configureFailure)
  windowManagement.run("full")
  currentFrame = { x = 300, y = 100, w = 700, h = 500 }
  configureMinimumCorrection({ h = 600 })
  configureFailure()
  local priorAlerts, priorFrames = #alerts, #setFrames
  press({ "cmd", "ctrl" }, "n")
  while activeTimerCount() > 0 do fireTimer(latestTimer) end
  assertFailureAlert(priorAlerts, message .. " notification")
  assertEqual(#setFrames, priorFrames + 1, message .. " only performs initial setFrame")
  assertEqual(activeTimerCount(), 0, message .. " leaves no timer")
  clearCorrectionMock()
end

assertInitialCorrectionFailure("unstable minimum-size correction", function()
  setReadback({
    { x = 300, y = 30, w = 700, h = 600 },
    { x = 300, y = 31, w = 700, h = 600 },
    { x = 300, y = 32, w = 700, h = 600 },
  })
end)

local function assertCorrectiveSetFrameFailure()
  windowManagement.run("full")
  currentFrame = { x = 300, y = 100, w = 700, h = 500 }
  configureMinimumCorrection({ h = 600 })
  correctiveSetFrameFailure = "error"
  local priorAlerts, priorFrames, priorAttempts = #alerts, #setFrames, setFrameAttempts
  press({ "cmd", "ctrl" }, "n")
  while activeTimerCount() > 0 do fireTimer(latestTimer) end
  correctiveSetFrameFailure = nil
  assertFailureAlert(priorAlerts, "corrective setFrame exception notification")
  assertEqual(#setFrames, priorFrames + 1, "corrective setFrame exception records only initial setFrame")
  assert(setFrameAttempts >= priorAttempts + 2, "corrective setFrame exception reaches second setFrame")
  assertEqual(activeTimerCount(), 0, "corrective setFrame exception leaves no timer")
  clearCorrectionMock()
end
assertCorrectiveSetFrameFailure()

local function assertFinalReadbackFailure(mode, frames, message)
  windowManagement.run("full")
  currentFrame = { x = 300, y = 100, w = 700, h = 500 }
  configureMinimumCorrection({ h = 600 })
  configureFinalReadback(mode, frames)
  local priorAlerts, priorFrames = #alerts, #setFrames
  press({ "cmd", "ctrl" }, "n")
  while activeTimerCount() > 0 do fireTimer(latestTimer) end
  assertFailureAlert(priorAlerts, message .. " notification")
  assertEqual(#setFrames, priorFrames + 2, message .. " reaches corrective setFrame")
  assertEqual(activeTimerCount(), 0, message .. " leaves no timer")
  clearCorrectionMock()
end

local function assertFinalReadbackBoundarySuccess()
  windowManagement.run("full")
  currentFrame = { x = 300, y = 100, w = 700, h = 500 }
  configureMinimumCorrection({ h = 600 })
  configureFinalReadback(nil, {
    { x = 302, y = 28, w = 698, h = 602 },
  })
  local priorAlerts, priorFrames = #alerts, #setFrames
  press({ "cmd", "ctrl" }, "n")
  while activeTimerCount() > 0 do fireTimer(latestTimer) end
  assertEqual(#alerts, priorAlerts, "final readback boundary success has no alert")
  assertEqual(#setFrames, priorFrames + 2, "final readback boundary success reaches corrective setFrame")
  assertEqual(activeTimerCount(), 0, "final readback boundary success leaves no timer")
  clearCorrectionMock()
end

assertFinalReadbackBoundarySuccess()
assertFinalReadbackFailure("nil", nil, "final readback nil")
assertFinalReadbackFailure("error", nil, "final readback exception")
assertFinalReadbackFailure(nil, {
  { x = 300, y = 31, w = 700, h = 600 },
  { x = 300, y = 32, w = 700, h = 600 },
  { x = 300, y = 33, w = 700, h = 600 },
}, "final readback instability")
assertFinalReadbackFailure(nil, {
  { x = 303, y = 30, w = 700, h = 600 },
  { x = 303, y = 30, w = 700, h = 600 },
  { x = 303, y = 30, w = 700, h = 600 },
}, "final readback beyond tolerance")

-- Readback tolerance is independent from exact setFrame target equality.
setReadback(nil)
assertNoAlert(function() press({ "cmd", "ctrl" }, "t") end, "immediate readback success")
assertEqual(readbackCalls, 1, "immediate readback attempt count")
setReadback({ { x = 0, y = 0, w = 1, h = 1 }, "current" })
local laterReadbackAlerts = #alerts
press({ "cmd", "ctrl" }, "t")
assertEqual(readbackCalls, 1, "later readback immediate attempt count")
local laterTimer = latestTimer
assertEqual(laterTimer.delay, 0.05, "later readback delay")
fireTimer(laterTimer)
assertEqual(readbackCalls, 2, "later readback second attempt count")
assertEqual(#alerts, laterReadbackAlerts, "later readback success has no alert")
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
local function assertInitialWindowFrameFailure(value, failureName)
  currentFrame = { x = -900, y = 350, w = 2600, h = 500 }
  initialWindowFrameFailure, initialWindowFrameValue = nil, nil
  if type(value) == "table" then initialWindowFrameValue = value else initialWindowFrameFailure = value end
  local priorAlerts, priorFrames = #alerts, #setFrames
  press({ "cmd", "ctrl" }, "t")
  initialWindowFrameFailure, initialWindowFrameValue = nil, nil
  assertFailureAlert(priorAlerts, failureName .. " notification")
  assertEqual(#setFrames, priorFrames, failureName .. " does not set a frame")
  assertEqual(activeTimerCount(), 0, failureName .. " leaves no timer")
end
assertInitialWindowFrameFailure("nil", "window:frame nil before setFrame")
assertInitialWindowFrameFailure("error", "window:frame exception before setFrame")
assertInitialWindowFrameFailure({ x = -900, y = 350, w = 2600 }, "window:frame missing field before setFrame")
assertInitialWindowFrameFailure({ x = -900, y = 350, w = "invalid", h = 500 }, "window:frame invalid field before setFrame")
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
local beforeMissingAlerts = #alerts
local missingScriptResult = utilityCommand.run(titleCaseExecutable, raycastRoot .. "/missing-title-case-chicago.sh")
assertEqual(missingScriptResult, false, "missing script returns false")
assertEqual(taskSequence, beforeMissingScript, "missing script does not create a task")
assertEqual(#alerts, beforeMissingAlerts, "missing script does not alert")

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
