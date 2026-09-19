local M = {}

local RETRY_DELAY_SECONDS = 0.05
local MAX_RETRY_COUNT = 20
local READBACK_DELAYS = { 0.1, 0.2, 0.4, 0.8, 1.2 }
local MAX_READBACK_COUNT = #READBACK_DELAYS
local retryTimer
local readbackTimer

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

local function mainScreenFrame()
  if type(hs) ~= "table" or type(hs.screen) ~= "table" or type(hs.screen.mainScreen) ~= "function" then
    return nil
  end
  local ok, screen = pcall(hs.screen.mainScreen)
  if not ok then return nil end
  return frameForScreen(screen)
end

local function targetScreenFrame()
  if type(hs) == "table" and type(hs.window) == "table" and type(hs.window.frontmostWindow) == "function" then
    local windowOK, window = pcall(hs.window.frontmostWindow)
    if windowOK and window and type(window.screen) == "function" then
      local screenOK, screen = pcall(window.screen, window)
      if screenOK then
        local frame = frameForScreen(screen)
        if frame then return frame end
      end
    end
  end
  return mainScreenFrame()
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

local function isStandardFinderWindow(window)
  if not window then return false end
  if type(window.role) == "function" then
    local ok, role = pcall(window.role, window)
    if ok and role and role ~= "AXWindow" then return false end
  end
  if type(window.subrole) == "function" then
    local ok, subrole = pcall(window.subrole, window)
    if ok and subrole and subrole ~= "AXStandardWindow" then return false end
  end
  return true
end

local function finderWindowsFromFilter()
  if type(hs) ~= "table" or type(hs.window) ~= "table"
      or type(hs.window.filter) ~= "table" or type(hs.window.filter.new) ~= "function" then
    return nil
  end
  local filterOK, filter = pcall(hs.window.filter.new, false)
  if not filterOK or not filter or type(filter.setAppFilter) ~= "function" or type(filter.getWindows) ~= "function" then
    return nil
  end
  if not pcall(filter.setAppFilter, filter, "Finder", {}) then return nil end
  local sortOrder = hs.window.filter.sortByCreated
  local windowsOK, windows = pcall(filter.getWindows, filter, sortOrder)
  if not windowsOK or type(windows) ~= "table" then return nil end
  return windows
end

local function finderWindows()
  local app = finderApplication()
  if not app then return nil, nil, "not-running" end
  if type(app.allWindows) ~= "function" then return nil, nil, "enumeration-failed" end
  local windowsOK, allWindows = pcall(app.allWindows, app)
  if windowsOK and type(allWindows) == "table" then
    local windows = {}
    for _, window in ipairs(allWindows) do
      if isStandardFinderWindow(window) then windows[#windows + 1] = window end
    end
    return windows, app, nil
  end
  local fallback = finderWindowsFromFilter()
  if fallback then return fallback, app, nil end
  return nil, nil, "enumeration-failed"
end

local function finderIsFrontmost()
  if type(hs) ~= "table" or type(hs.application) ~= "table"
      or type(hs.application.frontmostApplication) ~= "function" then
    return true
  end
  local ok, app = pcall(hs.application.frontmostApplication)
  if not ok or not app then return false end
  if type(app.name) == "function" then
    local nameOK, name = pcall(app.name, app)
    if nameOK and name then return name == "Finder" end
  end
  if type(app.bundleID) == "function" then
    local bundleOK, bundleID = pcall(app.bundleID, app)
    if bundleOK and bundleID then return bundleID == "com.apple.finder" end
  end
  return false
end

local function launchFinder()
  if type(hs) ~= "table" or type(hs.application) ~= "table" then return false end
  if type(hs.application.launchOrFocus) == "function" then
    local ok, result = pcall(hs.application.launchOrFocus, "Finder")
    return ok and result ~= false
  end
  if type(hs.application.open) == "function" then
    local ok, result = pcall(hs.application.open, "Finder")
    return ok and result ~= false
  end
  return false
end

local function activateFinder(app, window)
  app = app or finderApplication()
  if app and type(app.activate) == "function" then
    local ok, result = pcall(app.activate, app, true)
    if ok and result ~= false then
      if window and type(window.focus) == "function" then pcall(window.focus, window) end
      local focusedOK, focusedResult = pcall(app.activate, app, true)
      return focusedOK and focusedResult ~= false
    end
  end

  if type(hs) == "table" and type(hs.application) == "table"
      and type(hs.application.launchOrFocus) == "function" then
    local ok, result = pcall(hs.application.launchOrFocus, "Finder")
    return ok and result ~= false
  end
  return false
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

local function windowScreenFrame(window)
  if not window or type(window.screen) ~= "function" then return nil end
  local screenOK, screen = pcall(window.screen, window)
  if not screenOK then return nil end
  return frameForScreen(screen)
end

local function transitFrame(window, screenFrame)
  local current = nil
  if window and type(window.frame) == "function" then
    local frameOK, frame = pcall(window.frame, window)
    if frameOK and validFrame(frame) then current = frame end
  end
  local width = current and math.min(current.w, screenFrame.w) or math.min(800, screenFrame.w)
  local height = current and math.min(current.h, screenFrame.h) or math.min(600, screenFrame.h)
  return {
    x = screenFrame.x,
    y = screenFrame.y,
    w = math.max(1, width),
    h = math.max(1, height),
  }
end

local function moveToTargetScreen(window, screenFrame)
  if not window or type(window.setFrame) ~= "function" then return false end
  local currentScreenFrame = windowScreenFrame(window)
  if currentScreenFrame then
    if frameMatches(currentScreenFrame, screenFrame) then return true end
    local transit = transitFrame(window, screenFrame)
    local transitOK, transitResult = pcall(window.setFrame, window, transit, 0)
    return transitOK and transitResult ~= false
  end
  return true
end

local function schedulePlacementReadback(app, left, right, leftTarget, rightTarget, attempt)
  if type(left.frame) ~= "function" or type(right.frame) ~= "function" then return true end
  if type(hs) ~= "table" or type(hs.timer) ~= "table" or type(hs.timer.doAfter) ~= "function" then
    return false
  end

  local delay = READBACK_DELAYS[attempt] or READBACK_DELAYS[#READBACK_DELAYS]
  local timerOK, timer = pcall(hs.timer.doAfter, delay, function()
    readbackTimer = nil
    local leftOK, leftFrame = pcall(left.frame, left)
    local rightOK, rightFrame = pcall(right.frame, right)
    if leftOK and rightOK and frameMatches(leftFrame, leftTarget) and frameMatches(rightFrame, rightTarget)
        and finderIsFrontmost() then
      return
    end
    if attempt >= MAX_READBACK_COUNT then
      showError()
      return
    end
    activateFinder(app, left)
    if not schedulePlacementReadback(app, left, right, leftTarget, rightTarget, attempt + 1) then showError() end
  end)
  if not timerOK or not timer then return false end
  readbackTimer = timer
  return true
end

local function placeWindows(app, windows, screenFrame)
  if #windows < 2 then return false end
  local leftFrame, rightFrame = paneFrames(screenFrame)
  local left, right = windows[1], windows[2]
  if not left or not right or type(left.setFrame) ~= "function" or type(right.setFrame) ~= "function" then
    return false
  end

  -- Moving and resizing across displays in one AX operation can preserve the
  -- source display's maximum height. Move each window first, then resize it.
  if not moveToTargetScreen(left, screenFrame) or not moveToTargetScreen(right, screenFrame) then
    return false
  end

  local leftOK, leftResult = pcall(left.setFrame, left, leftFrame, 0)
  if not leftOK or leftResult == false then return false end
  local rightOK, rightResult = pcall(right.setFrame, right, rightFrame, 0)
  if not rightOK or rightResult == false then return false end
  if not activateFinder(app, left) then return false end
  if not schedulePlacementReadback(app, left, right, leftFrame, rightFrame, 1) then return false end
  return true
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

local function normalizeAndPlace(app, windows, screenFrame)
  if #windows > 2 and not closeExtraWindows(windows) then return false end
  return placeWindows(app, windows, screenFrame)
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

local function scheduleRetry(screenFrame, retriesRemaining)
  if retriesRemaining <= 0 then return fail() end
  if type(hs) ~= "table" or type(hs.timer) ~= "table" or type(hs.timer.doAfter) ~= "function" then
    return fail()
  end

  local callback
  callback = function()
    retryTimer = nil
    local windows, app, reason = finderWindows()
    if not windows then
      if reason == "not-running" and retriesRemaining > 1 then
        scheduleRetry(screenFrame, retriesRemaining - 1)
      else
        fail()
      end
      return
    end
    if #windows >= 2 then
      if not normalizeAndPlace(app, windows, screenFrame) then fail() end
      return
    end
    local missingCount = 2 - #windows
    for _ = 1, missingCount do
      if not createFinderWindow() then
        fail()
        return
      end
    end
    if retriesRemaining <= 1 then
      fail()
      return
    end
    scheduleRetry(screenFrame, retriesRemaining - 1)
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

  local screenFrame = targetScreenFrame()
  if not screenFrame then return fail() end

  local windows, app, reason = finderWindows()
  if not windows then
    if reason ~= "not-running" or not launchFinder() then return fail() end
    return scheduleRetry(screenFrame, MAX_RETRY_COUNT)
  end

  if #windows >= 2 then
    if not normalizeAndPlace(app, windows, screenFrame) then return fail() end
    return true
  end

  local missingCount = 2 - #windows
  for _ = 1, missingCount do
    if not createFinderWindow() then return fail() end
  end

  return scheduleRetry(screenFrame, MAX_RETRY_COUNT)
end

return M
