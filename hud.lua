local M = {}

local currentAlertID

local function showAlert(message, duration)
  if not hs.alert or not hs.alert.show then return nil end
  local style = {}
  local screen
  if hs.screen and type(hs.screen.mainScreen) == "function" then
    local screenOK, value = pcall(hs.screen.mainScreen)
    if screenOK then screen = value end
  end
  local ok, alertID
  if screen ~= nil then
    ok, alertID = pcall(hs.alert.show, message, style, screen, duration)
  else
    ok, alertID = pcall(hs.alert.show, message, style, {}, duration)
  end
  if not ok or alertID == nil then return nil end
  return alertID
end

local function closeAlert(alertID)
  if alertID == nil or not hs.alert or not hs.alert.closeSpecific then return false end
  local ok = pcall(hs.alert.closeSpecific, alertID)
  return ok
end

function M.close()
  local alertID = currentAlertID
  currentAlertID = nil
  return closeAlert(alertID)
end

function M.show(message)
  M.close()
  currentAlertID = showAlert(message, "indefinite")
  return currentAlertID ~= nil
end

function M.showTransient(message, seconds)
  return showAlert(message, seconds or 2)
end

function M.closeTransient(alertID)
  return closeAlert(alertID)
end

return M
