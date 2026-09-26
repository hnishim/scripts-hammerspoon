local M = {}

local cornerRadius = 20
local flashColor = { red = 0.40, green = 0.70, blue = 1.00 }
local opacity = 0.30
local fadeSeconds = 0.30

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
    or frame.w <= 0 or frame.h <= 0 or id == lastWindowID then
    return
  end

  removeOverlay()
  local drawn = pcall(function()
    overlay = hs.canvas.new(frame)
    overlay:appendElements({
      type = "rectangle",
      action = "fill",
      frame = { x = 0, y = 0, w = "100%", h = "100%" },
      roundedRectRadii = { xRadius = cornerRadius, yRadius = cornerRadius },
      fillColor = { red = flashColor.red, green = flashColor.green, blue = flashColor.blue, alpha = opacity },
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
