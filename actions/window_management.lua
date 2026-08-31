local M = {}

local mimiState = { direction = nil, cycle = 0 }
local pendingReadbackTimer
local operationSequence = 0
local layoutDefinitions = {
  bottom = { direction = 1, layouts = {{ width = 1, height = 0.5, anchor = "bl", preserveHorizontal = true }, { width = 1, height = 2 / 3, anchor = "bl", preserveHorizontal = true }, { width = 1, height = 0.5, anchor = "bl", preserveHorizontal = true }} },
  center = { direction = 2, layouts = {{ width = 0.5, height = 1, anchor = "cc" }, { width = 1 / 3, height = 1, anchor = "cc" }, { width = 2 / 3, height = 1, anchor = "cc" }} },
  left = { direction = 3, layouts = {{ width = 0.5, height = 1, anchor = "tl" }, { width = 1 / 3, height = 1, anchor = "tl" }, { width = 2 / 3, height = 1, anchor = "tl" }} },
  right = { direction = 4, layouts = {{ width = 0.5, height = 1, anchor = "tr" }, { width = 1 / 3, height = 1, anchor = "tr" }, { width = 2 / 3, height = 1, anchor = "tr" }} },
  top = { direction = 5, layouts = {{ width = 1, height = 0.5, anchor = "tl", preserveHorizontal = true }, { width = 1, height = 2 / 3, anchor = "tl", preserveHorizontal = true }, { width = 1, height = 0.5, anchor = "tl", preserveHorizontal = true }} },
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
local function validNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function validFrame(frame)
  if type(frame) ~= "table" then return false end
  for _, field in ipairs({ "x", "y", "w", "h" }) do
    if not validNumber(frame[field]) then return false end
  end
  return frame.w > 0 and frame.h > 0
end
local function makeTarget(frame, layout, currentFrame)
  if not validFrame(frame) then return nil end
  if layout.preserveHorizontal then
    if not validFrame(currentFrame) then return nil end
  end
  local left, top = rounded(frame.x), rounded(frame.y)
  local right, bottom = rounded(frame.x + frame.w), rounded(frame.y + frame.h)
  local width, height = rounded(frame.w * layout.width), rounded(frame.h * layout.height)
  local x, y = left, top
  if layout.preserveHorizontal then
    x, width = currentFrame.x, currentFrame.w
    if layout.anchor == "bl" then y = bottom - height end
  elseif layout.anchor == "bl" then y = bottom - height
  elseif layout.anchor == "cc" then x, y = rounded((left + right - width) / 2), rounded((top + bottom - height) / 2)
  elseif layout.anchor == "tr" then x = right - width end
  return { x = x, y = y, w = width, h = height }
end
local function frameMatches(actual, target)
  if not validFrame(actual) or not validFrame(target) then return false end
  for _, field in ipairs({ "x", "y", "w", "h" }) do if math.abs(actual[field] - target[field]) > 2 then return false end end
  return true
end

local function sameFrame(first, second)
  if not validFrame(first) or not validFrame(second) then return false end
  for _, field in ipairs({ "x", "y", "w", "h" }) do if first[field] ~= second[field] then return false end end
  return true
end

local function correctionCandidate(previous, current, target)
  if not validFrame(previous) or not validFrame(current) then return nil end
  if sameFrame(previous, current) and (current.w ~= target.w or current.h ~= target.h) then return current end
  return nil
end

local function clampCorrectedFrame(frame, screenFrame)
  if not validFrame(frame) or not validFrame(screenFrame) then return nil end
  if frame.w > screenFrame.w or frame.h > screenFrame.h then return nil end
  local right = screenFrame.x + screenFrame.w
  local bottom = screenFrame.y + screenFrame.h
  local x = math.max(screenFrame.x, math.min(frame.x, right - frame.w))
  local y = math.max(screenFrame.y, math.min(frame.y, bottom - frame.h))
  return { x = x, y = y, w = frame.w, h = frame.h }
end

local function correctedTarget(screenFrame, layout, requested, observed)
  if not validFrame(screenFrame) or not validFrame(requested) or not validFrame(observed) then return nil end
  local left, top = rounded(screenFrame.x), rounded(screenFrame.y)
  local right, bottom = rounded(screenFrame.x + screenFrame.w), rounded(screenFrame.y + screenFrame.h)
  local target = { x = requested.x, y = requested.y, w = observed.w, h = observed.h }
  if layout.preserveHorizontal then
    target.x = requested.x
    if layout.anchor == "bl" then target.y = bottom - target.h else target.y = top end
  elseif layout.anchor == "bl" then
    target.y = bottom - target.h
  elseif layout.anchor == "cc" then
    target.x, target.y = rounded((left + right - target.w) / 2), rounded((top + bottom - target.h) / 2)
  elseif layout.anchor == "tr" then
    target.x = right - target.w
  end
  return clampCorrectedFrame(target, screenFrame)
end

local readback
local function scheduleReadback(window, target, operation, attempt, context)
  if attempt >= 3 then pendingReadbackTimer = nil; showError(); return end
  local delay = attempt == 1 and 0.05 or 0.1
  local timerOK, timer = pcall(function() return hs.timer.doAfter(delay, function()
    if operation ~= operationSequence then return end
    pendingReadbackTimer = nil
    readback(window, target, operation, attempt + 1, context)
  end) end)
  if not timerOK or not timer then pendingReadbackTimer = nil; showError(); return end
  pendingReadbackTimer = timer
end

local function applyCorrection(window, context)
  local target = correctedTarget(context.screenFrame, context.layout, context.requested, context.candidate)
  if not target then pendingReadbackTimer = nil; showError(); return end
  local setOK = pcall(function() window:setFrame(target, 0) end)
  if not setOK then pendingReadbackTimer = nil; showError(); return end
  context.phase = "final"
  context.finalTarget = target
  context.finalObservations = {}
  readback(window, target, context.operation, 1, context)
end

readback = function(window, target, operation, attempt, context)
  if operation ~= operationSequence then return end
  if context.phase == "initial" and context.candidate then
    applyCorrection(window, context)
    return
  end
  local frameOK, frame = pcall(function() return window:frame() end)
  if context.phase == "final" then
    if not frameOK or not validFrame(frame) then pendingReadbackTimer = nil; showError(); return end
    if not frameMatches(frame, target) then pendingReadbackTimer = nil; showError(); return end
    local previous = context.finalObservations[#context.finalObservations]
    context.finalObservations[#context.finalObservations + 1] = frame
    if previous and sameFrame(previous, frame) then pendingReadbackTimer = nil; return end
    scheduleReadback(window, target, operation, attempt, context)
    return
  end
  if frameOK and frameMatches(frame, target) then pendingReadbackTimer = nil; return end
  if context.phase == "initial" and frameOK and validFrame(frame) then
    local previous = context.observations[#context.observations]
    context.observations[#context.observations + 1] = frame
    context.candidate = correctionCandidate(previous, frame, target)
  end
  scheduleReadback(window, target, operation, attempt, context)
end
local function resizeWindow(layout)
  cancelReadback(); operationSequence = operationSequence + 1
  local operation = operationSequence
  local windowOK, window = pcall(function() return hs.window.frontmostWindow() end)
  if not windowOK or not window then showError(); return false end
  local screenOK, screen = pcall(function() return window:screen() end)
  if not screenOK or not screen then showError(); return false end
  local frameOK, frame = pcall(function() return screen:frame() end)
  local currentFrame
  if layout.preserveHorizontal then
    local currentFrameOK
    currentFrameOK, currentFrame = pcall(function() return window:frame() end)
    if not currentFrameOK then currentFrame = nil end
  end
  local target = frameOK and makeTarget(frame, layout, currentFrame) or nil
  if not target then showError(); return false end
  local setOK = pcall(function() window:setFrame(target, 0) end)
  if not setOK then showError(); return false end
  readback(window, target, operation, 1, {
    operation = operation,
    phase = "initial",
    observations = {},
    candidate = nil,
    layout = layout,
    requested = target,
    screenFrame = frame,
  })
  return true
end
local function moveToPreviousDisplay()
  cancelReadback(); operationSequence = operationSequence + 1
  local windowOK, window = pcall(function() return hs.window.frontmostWindow() end)
  if not windowOK or not window then showError(); return false end
  local screenOK, screen = pcall(function() return window:screen() end)
  if not screenOK or not screen then showError(); return false end
  local screensOK, screens = pcall(function() return hs.screen.allScreens() end)
  if not screensOK or type(screens) ~= "table" then showError(); return false end
  if #screens < 2 then return true end
  local targetOK, target = pcall(function() return screen:previous() end)
  if not targetOK or not target then showError(); return false end
  local moveOK = pcall(function() window:moveToScreen(target, false, true, 0) end)
  if not moveOK then showError(); return false end
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
  if commandName == "previous-display" then return moveToPreviousDisplay() end
  if commandName == "full" then return maximize() end
  if layoutDefinitions[commandName] then return resizeWindow(nextLayout(layoutDefinitions[commandName])) end
  return false
end
return M
