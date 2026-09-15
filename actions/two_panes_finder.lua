local M = {}

local RETRY_DELAY_SECONDS = 0.05
local MAX_RETRY_COUNT = 20
local retryTimer

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

local function finderWindows()
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

  local sortOrder = hs.window.filter.sortByCreated
  local windowsOK, windows = pcall(filter.getWindows, filter, sortOrder)
  if not windowsOK or type(windows) ~= "table" then return nil end
  return windows
end

local function activateFinder()
  local app
  if type(hs) == "table" and type(hs.application) == "table" then
    if type(hs.application.get) == "function" then
      local ok, value = pcall(hs.application.get, "Finder")
      if ok then app = value end
    end
    if not app and type(hs.application.find) == "function" then
      local ok, value = pcall(hs.application.find, "Finder")
      if ok then app = value end
    end
  end

  if app and type(app.activate) == "function" then
    local ok, result = pcall(app.activate, app)
    return ok and result ~= false
  end

  if type(hs) == "table" and type(hs.application) == "table"
      and type(hs.application.launchOrFocus) == "function" then
    local ok, result = pcall(hs.application.launchOrFocus, "Finder")
    return ok and result ~= false
  end
  return false
end

local function placeWindows(windows, screenFrame)
  if #windows < 2 then return false end
  local leftFrame, rightFrame = paneFrames(screenFrame)
  local left, right = windows[1], windows[2]
  if not left or not right or type(left.setFrame) ~= "function" or type(right.setFrame) ~= "function" then
    return false
  end

  local leftOK, leftResult = pcall(left.setFrame, left, leftFrame, 0)
  if not leftOK or leftResult == false then return false end
  local rightOK, rightResult = pcall(right.setFrame, right, rightFrame, 0)
  if not rightOK or rightResult == false then return false end
  return activateFinder()
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

local function normalizeAndPlace(windows, screenFrame)
  if #windows > 2 and not closeExtraWindows(windows) then return false end
  return placeWindows(windows, screenFrame)
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
  if not timer then return end
  if type(timer.stop) == "function" then
    pcall(timer.stop, timer)
  elseif type(hs) == "table" and type(hs.timer) == "table" and type(hs.timer.stop) == "function" then
    pcall(hs.timer.stop, timer)
  end
end

local function scheduleRetry(screenFrame, retriesRemaining)
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
      if not normalizeAndPlace(windows, screenFrame) then fail() end
      return
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
end

function M.run()
  M.stop()

  local screenFrame = targetScreenFrame()
  if not screenFrame then return fail() end

  local windows = finderWindows()
  if not windows then return fail() end

  if #windows >= 2 then
    if not normalizeAndPlace(windows, screenFrame) then return fail() end
    return true
  end

  local missingCount = 2 - #windows
  for _ = 1, missingCount do
    if not createFinderWindow() then return fail() end
  end

  return scheduleRetry(screenFrame, MAX_RETRY_COUNT)
end

return M
