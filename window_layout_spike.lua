local M = {}

local modifiers = { "cmd", "alt", "shift" }
local key = "l"
local hotkey = nil

local function showAlert(message)
  if hs.alert and hs.alert.show then pcall(hs.alert.show, message, 2) end
end

local function round(value)
  return math.floor(value + 0.5)
end

local function frameMatches(actual, expected)
  return actual.x == expected.x
    and actual.y == expected.y
    and actual.w == expected.w
    and actual.h == expected.h
end

local function resizeFrontmost()
  local windowOK, window = pcall(hs.window.frontmostWindow)
  if not windowOK or not window then
    showAlert("対象ウィンドウを取得できませんでした。")
    return
  end

  local screenOK, screen = pcall(function() return window:screen() end)
  if not screenOK or not screen then
    showAlert("画面を取得できませんでした。")
    return
  end

  local frameOK, frame = pcall(function() return screen:frame() end)
  if not frameOK or not frame then
    showAlert("画面フレームを取得できませんでした。")
    return
  end

  local height = round(frame.h * 0.5)
  local targetFrame = {
    x = round(frame.x),
    y = round(frame.y + frame.h - height),
    w = round(frame.w),
    h = height,
  }

  local setFrameOK = pcall(function() window:setFrame(targetFrame, 0) end)
  if not setFrameOK then
    showAlert("ウィンドウをリサイズできませんでした。")
    return
  end

  local actualFrameOK, actualFrame = pcall(function() return window:frame() end)
  if not actualFrameOK or not actualFrame or not frameMatches(actualFrame, targetFrame) then
    showAlert("ウィンドウをリサイズできませんでした。")
    return
  end

  showAlert("ウィンドウをリサイズしました。")
end

local function deleteHotkey()
  if not hotkey then return end
  pcall(hotkey.delete, hotkey)
  hotkey = nil
end

function M.start()
  deleteHotkey()

  local bindOK, binding = pcall(hs.hotkey.bind, modifiers, key, resizeFrontmost)
  if not bindOK or not binding then
    showAlert("ホットキーを登録できませんでした。")
    return false
  end

  hotkey = binding
  return true
end

function M.stop()
  deleteHotkey()
end

return M
