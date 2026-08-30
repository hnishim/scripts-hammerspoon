local M = {}

local mimiState = { direction = nil, cycle = 0 }
local pendingReadbackTimer
local operationSequence = 0
local layoutDefinitions = {
  bottom = { direction = 1, layouts = {{ width = 1, height = 0.5, anchor = "bl" }, { width = 1, height = 1 / 3, anchor = "bl" }, { width = 1, height = 2 / 3, anchor = "bl" }} },
  center = { direction = 2, layouts = {{ width = 0.5, height = 1, anchor = "cc" }, { width = 1 / 3, height = 1, anchor = "cc" }, { width = 2 / 3, height = 1, anchor = "cc" }} },
  left = { direction = 3, layouts = {{ width = 0.5, height = 1, anchor = "tl" }, { width = 1 / 3, height = 1, anchor = "tl" }, { width = 2 / 3, height = 1, anchor = "tl" }} },
  right = { direction = 4, layouts = {{ width = 0.5, height = 1, anchor = "tr" }, { width = 1 / 3, height = 1, anchor = "tr" }, { width = 2 / 3, height = 1, anchor = "tr" }} },
  top = { direction = 5, layouts = {{ width = 1, height = 0.5, anchor = "tl" }, { width = 1, height = 1 / 3, anchor = "tl" }, { width = 1, height = 2 / 3, anchor = "tl" }} },
}

local function showError()
  if hs.alert and hs.alert.show then pcall(hs.alert.show, "コマンドを実行できませんでした。", 2) end
end
local function cancelReadback()
  if not pendingReadbackTimer then return end
  if hs.timer and hs.timer.stop then pcall(hs.timer.stop, pendingReadbackTimer)
  elseif pendingReadbackTimer.stop then pcall(pendingReadbackTimer.stop, pendingReadbackTimer) end
  pendingReadbackTimer = nil
end
local function rounded(value) return math.floor(value + 0.5) end
local function makeTarget(frame, layout)
  if type(frame) ~= "table" then return nil end
  for _, field in ipairs({ "x", "y", "w", "h" }) do if type(frame[field]) ~= "number" then return nil end end
  local left, top = rounded(frame.x), rounded(frame.y)
  local right, bottom = rounded(frame.x + frame.w), rounded(frame.y + frame.h)
  local width, height = rounded(frame.w * layout.width), rounded(frame.h * layout.height)
  local x, y = left, top
  if layout.anchor == "bl" then y = bottom - height
  elseif layout.anchor == "cc" then x, y = rounded((left + right - width) / 2), rounded((top + bottom - height) / 2)
  elseif layout.anchor == "tr" then x = right - width end
  return { x = x, y = y, w = width, h = height }
end
local function frameMatches(actual, target)
  if type(actual) ~= "table" then return false end
  for _, field in ipairs({ "x", "y", "w", "h" }) do if type(actual[field]) ~= "number" or math.abs(actual[field] - target[field]) > 2 then return false end end
  return true
end
local function readback(window, target, operation, attempt)
  if operation ~= operationSequence then return end
  local frameOK, frame = pcall(function() return window:frame() end)
  if frameOK and frameMatches(frame, target) then pendingReadbackTimer = nil; return end
  if attempt >= 3 then pendingReadbackTimer = nil; showError(); return end
  local delay = attempt == 1 and 0.05 or 0.1
  local timerOK, timer = pcall(function() return hs.timer.doAfter(delay, function()
    if operation ~= operationSequence then return end
    pendingReadbackTimer = nil
    readback(window, target, operation, attempt + 1)
  end) end)
  if not timerOK or not timer then pendingReadbackTimer = nil; showError(); return end
  pendingReadbackTimer = timer
end
local function resizeWindow(layout)
  cancelReadback(); operationSequence = operationSequence + 1
  local operation = operationSequence
  local windowOK, window = pcall(function() return hs.window.frontmostWindow() end)
  if not windowOK or not window then showError(); return false end
  local screenOK, screen = pcall(function() return window:screen() end)
  if not screenOK or not screen then showError(); return false end
  local frameOK, frame = pcall(function() return screen:frame() end)
  local target = frameOK and makeTarget(frame, layout) or nil
  if not target then showError(); return false end
  local setOK = pcall(function() window:setFrame(target, 0) end)
  if not setOK then showError(); return false end
  readback(window, target, operation, 1)
  return true
end
local function nextLayout(command)
  if mimiState.direction ~= command.direction then mimiState.direction, mimiState.cycle = command.direction, 1
  elseif mimiState.cycle == 1 then mimiState.cycle = 2
  elseif mimiState.cycle == 2 then mimiState.cycle = 0
  else mimiState.cycle = 1 end
  return command.layouts[mimiState.cycle == 0 and 3 or mimiState.cycle]
end
local function maximize()
  mimiState.direction, mimiState.cycle = nil, 0
  return resizeWindow({ width = 1, height = 1, anchor = "tl" })
end
function M.stop()
  operationSequence = operationSequence + 1
  cancelReadback()
end
function M.run(commandName)
  if commandName == "full" then return maximize() end
  if layoutDefinitions[commandName] then return resizeWindow(nextLayout(layoutDefinitions[commandName])) end
  return false
end
return M
