local M = {}

local RETRY_DELAY_SECONDS = 0.05
local MAX_RETRY_COUNT = 20
local MAX_READBACK_COUNT = 5
local retryTimer
local readbackTimer
local finderWindowFilter

local function showError()
  if type(hs) == "table" and type(hs.alert) == "table" and type(hs.alert.show) == "function" then
    pcall(hs.alert.show, "Finderウィンドウを配置できませんでした。", 2)
  end
end

local function fail()
  showError()
  return false
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validFrame(frame)
  if type(frame) ~= "table" then return false end
  return isFiniteNumber(frame.x)
    and isFiniteNumber(frame.y)
    and isFiniteNumber(frame.w)
    and isFiniteNumber(frame.h)
    and frame.w > 0
    and frame.h > 0
end

local function frameMatches(actual, target)
  if not validFrame(actual) or not validFrame(target) then return false end
  for _, field in ipairs({ "x", "y", "w", "h" }) do
    if math.abs(actual[field] - target[field]) > 2 then return false end
  end
  return true
end

local function frameForScreen(screen)
  if not screen or type(screen.frame) ~= "function" then return nil end
  local ok, frame = pcall(screen.frame, screen)
  if not ok or not validFrame(frame) then return nil end
  return frame
end

local function mainScreen()
  if type(hs) ~= "table" or type(hs.screen) ~= "table" or type(hs.screen.mainScreen) ~= "function" then
    return nil
  end
  local ok, screen = pcall(hs.screen.mainScreen)
  if not ok or not screen or not frameForScreen(screen) then return nil end
  return screen
end

local function targetScreen()
  if type(hs) == "table" and type(hs.window) == "table" and type(hs.window.frontmostWindow) == "function" then
    local windowOK, window = pcall(hs.window.frontmostWindow)
    if windowOK and window and type(window.screen) == "function" then
      local screenOK, screen = pcall(window.screen, window)
      if screenOK and screen and frameForScreen(screen) then return screen end
    end
  end
  return mainScreen()
end

local function paneFrames(frame)
  local leftWidth = math.floor(frame.w / 2)
  return {
    x = frame.x,
    y = frame.y,
    w = leftWidth,
    h = frame.h,
  }, {
    x = frame.x + leftWidth,
    y = frame.y,
    w = frame.w - leftWidth,
    h = frame.h,
  }
end

local function createFinderWindowFilter()
  if type(hs) ~= "table" or type(hs.window) ~= "table"
      or type(hs.window.filter) ~= "table" or type(hs.window.filter.new) ~= "function" then
    return nil
  end

  local filterOK, filter = pcall(hs.window.filter.new, false)
  if not filterOK or not filter or type(filter.setAppFilter) ~= "function" or type(filter.getWindows) ~= "function" then
    return nil
  end

  local appFilterOK = pcall(filter.setAppFilter, filter, "Finder", {})
  if not appFilterOK then return nil end
  return filter
end

finderWindowFilter = createFinderWindowFilter()

local function finderWindows()
  if not finderWindowFilter or type(finderWindowFilter.getWindows) ~= "function" then return nil end
  local sortOrder = hs.window.filter.sortByCreated
  local windowsOK, windows = pcall(finderWindowFilter.getWindows, finderWindowFilter, sortOrder)
  if not windowsOK or type(windows) ~= "table" then return nil end
  return windows
end

local function finderApplication()
  if type(hs) ~= "table" or type(hs.application) ~= "table" then return nil end
  if type(hs.application.get) == "function" then
    local ok, app = pcall(hs.application.get, "Finder")
    if ok and app then return app end
  end
  if type(hs.application.find) == "function" then
    local ok, app = pcall(hs.application.find, "Finder")
    if ok and app then return app end
  end
  return nil
end

local function activateFinder()
  local app = finderApplication()
  if app and type(app.activate) == "function" then
    local ok, result = pcall(app.activate, app, true)
    return ok and result ~= false
  end

  if type(hs) == "table" and type(hs.application) == "table"
      and type(hs.application.launchOrFocus) == "function" then
    local ok, result = pcall(hs.application.launchOrFocus, "Finder")
    return ok and result ~= false
  end
  return false
end

local function finderIsFrontmost()
  if type(hs) ~= "table" or type(hs.application) ~= "table"
      or type(hs.application.frontmostApplication) ~= "function" then
    return nil
  end

  local appOK, app = pcall(hs.application.frontmostApplication)
  if not appOK or not app or type(app.name) ~= "function" then return nil end
  local nameOK, name = pcall(app.name, app)
  if not nameOK then return nil end
  return name == "Finder"
end

local function screenMatchesTarget(window, screen)
  if not window or type(window.screen) ~= "function" then return true end
  local windowScreenOK, windowScreen = pcall(window.screen, window)
  if not windowScreenOK or not windowScreen then return false end
  local windowFrame = frameForScreen(windowScreen)
  local targetFrame = frameForScreen(screen)
  return windowFrame ~= nil and targetFrame ~= nil and frameMatches(windowFrame, targetFrame)
end

local function moveWindowToTargetScreen(window, screen)
  if not window or not screen or type(window.moveToScreen) ~= "function" then return true end
  if screenMatchesTarget(window, screen) then return true end

  local ok, result = pcall(window.moveToScreen, window, screen, true, true, 0)
  return ok and result ~= false
end

local function raiseWindow(window)
  if not window or type(window.raise) ~= "function" then return true end
  local ok, result = pcall(window.raise, window)
  return ok and result ~= false
end

local function bringFinderForward(left, right)
  if not raiseWindow(left) then return false end
  if not raiseWindow(right) then return false end
  return activateFinder()
end

local function stopTimer(timer)
  if not timer then return end
  if type(timer.stop) == "function" then
    pcall(timer.stop, timer)
  elseif type(hs) == "table" and type(hs.timer) == "table" and type(hs.timer.stop) == "function" then
    pcall(hs.timer.stop, timer)
  end
end

local function stopReadbackTimer()
  local timer = readbackTimer
  readbackTimer = nil
  stopTimer(timer)
end

local function placeWindowFrames(left, right, screen)
  if not left or not right or not screen then return nil, nil end
  if type(left.setFrame) ~= "function" or type(right.setFrame) ~= "function" then return nil, nil end

  local screenFrame = frameForScreen(screen)
  if not screenFrame then return nil, nil end
  local leftTarget, rightTarget = paneFrames(screenFrame)

  if not moveWindowToTargetScreen(left, screen) then return nil, nil end
  if not moveWindowToTargetScreen(right, screen) then return nil, nil end

  local leftOK, leftResult = pcall(left.setFrame, left, leftTarget, 0)
  if not leftOK or leftResult == false then return nil, nil end
  local rightOK, rightResult = pcall(right.setFrame, right, rightTarget, 0)
  if not rightOK or rightResult == false then return nil, nil end

  return leftTarget, rightTarget
end

local function placementMatches(left, right, screen, leftTarget, rightTarget)
  if type(left.frame) ~= "function" or type(right.frame) ~= "function" then return true end

  local leftOK, leftFrame = pcall(left.frame, left)
  local rightOK, rightFrame = pcall(right.frame, right)
  if not leftOK or not rightOK
      or not frameMatches(leftFrame, leftTarget)
      or not frameMatches(rightFrame, rightTarget) then
    return false
  end

  if not screenMatchesTarget(left, screen) or not screenMatchesTarget(right, screen) then return false end

  local frontmost = finderIsFrontmost()
  return frontmost ~= false
end

local schedulePlacementReadback

schedulePlacementReadback = function(left, right, screen, leftTarget, rightTarget, attempt)
  if type(left.frame) ~= "function" or type(right.frame) ~= "function" then return true end
  if type(hs) ~= "table" or type(hs.timer) ~= "table" or type(hs.timer.doAfter) ~= "function" then
    return false
  end

  local delay = attempt == 1 and 0.05 or 0.1
  local timerOK, timer = pcall(hs.timer.doAfter, delay, function()
    readbackTimer = nil

    local currentScreenFrame = frameForScreen(screen)
    if not currentScreenFrame then
      screen = mainScreen()
      currentScreenFrame = frameForScreen(screen)
    end
    if not screen or not currentScreenFrame then
      showError()
      return
    end

    local currentLeftTarget, currentRightTarget = paneFrames(currentScreenFrame)
    if placementMatches(left, right, screen, currentLeftTarget, currentRightTarget) then return end

    if attempt >= MAX_READBACK_COUNT then
      showError()
      return
    end

    local reappliedLeft, reappliedRight = placeWindowFrames(left, right, screen)
    if not reappliedLeft or not reappliedRight or not bringFinderForward(left, right) then
      showError()
      return
    end

    if not schedulePlacementReadback(
        left, right, screen, reappliedLeft, reappliedRight, attempt + 1) then
      showError()
    end
  end)
  if not timerOK or not timer then return false end
  readbackTimer = timer
  return true
end

local function placeWindows(windows, screen)
  if #windows < 2 or not screen then return false end
  local left, right = windows[1], windows[2]

  local leftTarget, rightTarget = placeWindowFrames(left, right, screen)
  if not leftTarget or not rightTarget then return false end

  if not schedulePlacementReadback(left, right, screen, leftTarget, rightTarget, 1) then return false end
  return bringFinderForward(left, right)
end

local function closeExtraWindows(windows)
  for index = #windows, 3, -1 do
    local window = windows[index]
    if not window or type(window.close) ~= "function" then return false end
    local ok, result = pcall(window.close, window)
    if not ok or result == false then return false end
  end
  return true
end

local function normalizeAndPlace(windows, screen)
  if #windows > 2 and not closeExtraWindows(windows) then return false end
  return placeWindows(windows, screen)
end

local function createFinderWindow()
  if type(hs) ~= "table" or type(hs.osascript) ~= "table"
      or type(hs.osascript.applescript) ~= "function" then
    return false
  end
  local source = [[
tell application "Finder"
  make new Finder window to desktop
end tell
]]
  local callOK, scriptOK = pcall(hs.osascript.applescript, source)
  return callOK and scriptOK == true
end

local function stopRetryTimer()
  local timer = retryTimer
  retryTimer = nil
  stopTimer(timer)
end

local function scheduleRetry(screen, retriesRemaining)
  if retriesRemaining <= 0 then return fail() end
  if type(hs) ~= "table" or type(hs.timer) ~= "table" or type(hs.timer.doAfter) ~= "function" then
    return fail()
  end

  local callback
  callback = function()
    retryTimer = nil
    local windows = finderWindows()
    if not windows then
      fail()
      return
    end
    if #windows >= 2 then
      if not normalizeAndPlace(windows, screen) then fail() end
      return
    end
    if retriesRemaining <= 1 then
      fail()
      return
    end
    scheduleRetry(screen, retriesRemaining - 1)
  end

  local timerOK, timer = pcall(hs.timer.doAfter, RETRY_DELAY_SECONDS, callback)
  if not timerOK or not timer then return fail() end
  retryTimer = timer
  return true
end

function M.stop()
  stopRetryTimer()
  stopReadbackTimer()
end

function M.run()
  M.stop()

  local screen = targetScreen()
  if not screen then return fail() end

  local windows = finderWindows()
  if not windows then return fail() end

  if #windows >= 2 then
    if not normalizeAndPlace(windows, screen) then return fail() end
    return true
  end

  local missingCount = 2 - #windows
  for _ = 1, missingCount do
    if not createFinderWindow() then return fail() end
  end

  return scheduleRetry(screen, MAX_RETRY_COUNT)
end

return M
