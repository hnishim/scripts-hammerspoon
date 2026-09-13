local M = {}

local STYLE = {
  height = 44,
  minWidth = 140,
  maxWidth = 520,
  horizontalPadding = 14,
  indicatorWidth = 18,
  indicatorGap = 8,
  textSize = 18,
  indicatorSize = 14,
  cornerRadius = 12,
  backgroundColor = { red = 0.10, green = 0.10, blue = 0.12, alpha = 0.82 },
  textColor = { white = 1, alpha = 0.96 },
}

local indicatorFrames = { "◐", "◓", "◑", "◒" }
local persistent

local function stopTimer(timer)
  if not timer then return end
  if type(timer.stop) == "function" then
    pcall(timer.stop, timer)
  elseif hs.timer and type(hs.timer.stop) == "function" then
    pcall(hs.timer.stop, timer)
  end
end

local function deleteCanvas(canvas)
  if canvas and type(canvas.delete) == "function" then pcall(canvas.delete, canvas) end
end

local function closeRecord(record)
  if not record or record.closed then return false end
  record.closed = true
  stopTimer(record.animationTimer)
  stopTimer(record.timeoutTimer)
  record.animationTimer = nil
  record.timeoutTimer = nil
  deleteCanvas(record.canvas)
  record.canvas = nil
  return true
end

local function messageLength(message)
  if utf8 and type(utf8.len) == "function" then
    local ok, length = pcall(utf8.len, message)
    if ok and type(length) == "number" then return length end
  end
  return #message
end

local function validFrame(frame)
  if type(frame) ~= "table" then return false end
  for _, key in ipairs({ "x", "y", "w", "h" }) do
    local value = frame[key]
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
      return false
    end
  end
  return frame.w > 0 and frame.h > 0
end

local function mainScreenFrame()
  if not hs.screen or type(hs.screen.mainScreen) ~= "function" then return nil end
  local screenOK, screen = pcall(hs.screen.mainScreen)
  if not screenOK or not screen or type(screen.frame) ~= "function" then return nil end
  local frameOK, frame = pcall(screen.frame, screen)
  if not frameOK or not validFrame(frame) then return nil end
  return frame
end

local function makeFrame(screenFrame, message, animated)
  local indicatorSpace = animated and (STYLE.indicatorWidth + STYLE.indicatorGap) or 0
  local estimatedTextWidth = messageLength(message) * STYLE.textSize * 0.58
  local width = math.ceil(estimatedTextWidth + STYLE.horizontalPadding * 2 + indicatorSpace)
  width = math.max(STYLE.minWidth, math.min(STYLE.maxWidth, width))
  local height = STYLE.height
  return {
    x = math.floor(screenFrame.x + (screenFrame.w - width) / 2 + 0.5),
    y = math.floor(screenFrame.y + screenFrame.h * 0.75 - height / 2 + 0.5),
    w = width,
    h = height,
  }
end

local function addElement(canvas, index, element)
  local ok = pcall(function() canvas[index] = element end)
  return ok
end

local function setLevel(canvas)
  if type(canvas.level) ~= "function" then return end
  local levels = hs.canvas and hs.canvas.windowLevels
  local level = type(levels) == "table" and levels.floating or nil
  if level ~= nil then pcall(canvas.level, canvas, level) end
end

local function createCanvas(message, animated)
  if not hs.canvas or type(hs.canvas.new) ~= "function" then return nil end
  local screenFrame = mainScreenFrame()
  if not screenFrame then return nil end

  message = tostring(message or "")
  local frame = makeFrame(screenFrame, message, animated)
  local canvasOK, canvas = pcall(hs.canvas.new, frame)
  if not canvasOK or not canvas then return nil end

  local backgroundOK = addElement(canvas, 1, {
    type = "rectangle",
    action = "fill",
    frame = { x = 0, y = 0, w = frame.w, h = frame.h },
    fillColor = STYLE.backgroundColor,
    roundedRectRadii = { xRadius = STYLE.cornerRadius, yRadius = STYLE.cornerRadius },
    withShadow = true,
  })

  local textX = STYLE.horizontalPadding + (animated and (STYLE.indicatorWidth + STYLE.indicatorGap) or 0)
  local textOK = addElement(canvas, 2, {
    type = "text",
    text = message,
    textSize = STYLE.textSize,
    textColor = STYLE.textColor,
    textAlignment = "center",
    frame = {
      x = textX,
      y = 8,
      w = frame.w - textX - STYLE.horizontalPadding,
      h = frame.h - 16,
    },
  })

  local indicatorOK = true
  if animated then
    indicatorOK = addElement(canvas, 3, {
      type = "text",
      text = indicatorFrames[1],
      textSize = STYLE.indicatorSize,
      textColor = STYLE.textColor,
      textAlignment = "center",
      frame = {
        x = STYLE.horizontalPadding,
        y = 8,
        w = STYLE.indicatorWidth,
        h = frame.h - 16,
      },
    })
  end

  if not backgroundOK or not textOK or not indicatorOK then
    deleteCanvas(canvas)
    return nil
  end

  setLevel(canvas)
  local showOK = pcall(canvas.show, canvas)
  if not showOK then
    deleteCanvas(canvas)
    return nil
  end

  return { canvas = canvas, closed = false }
end

local function startAnimation(record)
  if not hs.timer or type(hs.timer.doEvery) ~= "function" then return false end
  local frameIndex = 1
  local timerOK, timer = pcall(hs.timer.doEvery, 0.12, function()
    if record.closed or not record.canvas then return end
    frameIndex = frameIndex % #indicatorFrames + 1
    if type(record.canvas.elementAttribute) == "function" then
      pcall(record.canvas.elementAttribute, record.canvas, 3, "text", indicatorFrames[frameIndex])
    else
      pcall(function()
        local element = record.canvas[3]
        if type(element) == "table" then
          element.text = indicatorFrames[frameIndex]
          record.canvas[3] = element
        end
      end)
    end
  end)
  if not timerOK or not timer then return false end
  record.animationTimer = timer
  return true
end

function M.close()
  local record = persistent
  persistent = nil
  return closeRecord(record)
end

function M.show(message)
  M.close()
  local record = createCanvas(message, true)
  if not record then return false end
  if not startAnimation(record) then
    closeRecord(record)
    return false
  end
  persistent = record
  return true
end

function M.showTransient(message, seconds)
  local record = createCanvas(message, false)
  if not record then return nil end
  local duration = tonumber(seconds)
  if duration == nil or duration < 0 then duration = 2 end
  if not hs.timer or type(hs.timer.doAfter) ~= "function" then
    closeRecord(record)
    return nil
  end
  local timerOK, timer = pcall(hs.timer.doAfter, duration, function()
    record.timeoutTimer = nil
    closeRecord(record)
  end)
  if not timerOK or not timer then
    closeRecord(record)
    return nil
  end
  record.timeoutTimer = timer
  return record
end

function M.closeTransient(record)
  return closeRecord(record)
end

return M
