local M = {}

local cornerRadius = 20
local strokeWidth = 4
local strokeColor = { red = 0.20, green = 0.65, blue = 1.00, alpha = 0.95 }
local fadeSeconds = 0.60

local watcher
local overlay
local lastWindowID

local function removeOverlay()
  if not overlay then return end
  local previous = overlay
  overlay = nil
  pcall(previous.delete, previous, 0)
end

local function focused(window)
  if not window then return end

  local ok, id, frame, standard = pcall(function()
    return window:id(), window:frame(), window:isStandard()
  end)
  if not ok or not id or standard == false or not frame
    or type(frame.w) ~= "number" or type(frame.h) ~= "number"
    or frame.w <= strokeWidth or frame.h <= strokeWidth or id == lastWindowID then
    return
  end

  removeOverlay()
  local drawn = pcall(function()
    overlay = hs.canvas.new(frame)
    overlay:appendElements({
      type = "rectangle",
      action = "stroke",
      frame = {
        x = strokeWidth / 2, y = strokeWidth / 2,
        w = frame.w - strokeWidth, h = frame.h - strokeWidth,
      },
      roundedRectRadii = { xRadius = cornerRadius, yRadius = cornerRadius },
      strokeWidth = strokeWidth,
      strokeColor = strokeColor,
    })
    overlay:clickActivating(false)
    if hs.canvas.windowLevels and hs.canvas.windowLevels.overlay then
      overlay:level(hs.canvas.windowLevels.overlay)
    end
    overlay:show()
    overlay:delete(fadeSeconds)
  end)
  if drawn then
    lastWindowID = id
  else
    removeOverlay()
  end
end

function M.stop()
  if watcher then
    pcall(watcher.unsubscribeAll, watcher)
    if watcher.delete then pcall(watcher.delete, watcher) end
    watcher = nil
  end
  removeOverlay()
  lastWindowID = nil
end

function M.start()
  M.stop()
  local ok, filter = pcall(function() return hs.window.filter.new(true) end)
  if not ok or not filter then return false end
  local subscribed = pcall(function()
    filter:subscribe(hs.window.filter.windowFocused, focused, false)
  end)
  if not subscribed then
    pcall(filter.unsubscribeAll, filter)
    if filter.delete then pcall(filter.delete, filter) end
    return false
  end
  watcher = filter
  return true
end

return M
