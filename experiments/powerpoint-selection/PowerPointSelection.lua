local M = {}

local function scriptCall(script)
  if type(hs) ~= "table" or type(hs.osascript) ~= "table"
      or type(hs.osascript.applescript) ~= "function" then
    return nil, "hs.osascript.applescript is unavailable"
  end

  local callOK, scriptOK, result = pcall(hs.osascript.applescript, script)
  if not callOK or scriptOK ~= true then
    return nil, "PowerPoint AppleScript failed"
  end
  return result
end

local function powerPointIsFrontmost()
  if type(hs) ~= "table" or type(hs.application) ~= "table"
      or type(hs.application.frontmostApplication) ~= "function" then
    return false, "hs.application.frontmostApplication is unavailable"
  end
  local callOK, application = pcall(hs.application.frontmostApplication)
  if not callOK or not application or type(application.bundleID) ~= "function" then
    return false, "frontmost application is unavailable"
  end
  local bundleOK, bundleID = pcall(application.bundleID, application)
  if not bundleOK or bundleID ~= "com.microsoft.Powerpoint" then
    return false, "PowerPoint is not frontmost"
  end
  return true
end

local CAPTURE_SCRIPT = [[
tell application id "com.microsoft.Powerpoint"
  if not running then error "PowerPoint is not running"
  if (count of presentations) is 0 then error "No active presentation"

  set presentationValue to active presentation
  set windowValue to active window
  set currentSlide to slide of view of active window
  set selectionValue to selection of windowValue
  set textRangeValue to text range of selectionValue
  if (selection type of selectionValue) is not selection type text then error "Selection is not a text selection"
  if (text length of textRangeValue) is 0 then error "Selection is empty"

  return {"Microsoft PowerPoint", name of presentationValue, (path of presentationValue as text), name of windowValue, caption of windowValue, entry_index of windowValue, slide index of currentSlide, slide ID of currentSlide, (selection type of selectionValue as text), offset of textRangeValue, text length of textRangeValue, content of textRangeValue, count of shape range of selectionValue}
end tell
]]

local SNAPSHOT_KEYS = {
  "applicationName", "presentationName", "presentationPath", "windowName", "windowCaption",
  "windowEntryIndex", "slideIndex", "slideID", "selectionType", "textOffset", "textLength",
  "selectedText", "shapeRangeCount",
}

local function mapCaptureResult(result)
  if type(result) ~= "table" or #result ~= #SNAPSHOT_KEYS then
    return nil, "PowerPoint capture returned an unexpected result"
  end
  local snapshot = {}
  for index, key in ipairs(SNAPSHOT_KEYS) do snapshot[key] = result[index] end
  return snapshot
end

local function same(a, b, key)
  return a[key] == b[key]
end

local function equalSnapshot(expected, actual)
  if type(expected) ~= "table" or type(actual) ~= "table" then return false end
  local keys = {
    "applicationName", "presentationName", "presentationPath", "windowName", "windowCaption",
    "windowEntryIndex", "slideIndex", "slideID",
    "selectionType", "textOffset", "textLength", "selectedText", "shapeRangeCount",
  }
  for _, key in ipairs(keys) do
    if not same(expected, actual, key) then return false end
  end
  return true
end

function M.capture()
  local frontmost, frontmostErr = powerPointIsFrontmost()
  if not frontmost then return nil, frontmostErr end
  local result, scriptErr = scriptCall(CAPTURE_SCRIPT)
  if not result then return nil, scriptErr end
  return mapCaptureResult(result)
end

function M.revalidate(expected)
  local actual, err = M.capture()
  if not actual then return false, err end
  if not equalSnapshot(expected, actual) then
    return false, "PowerPoint selection changed; refusing native write"
  end
  return true
end

function M.writeSelection(expected, replacement)
  if type(replacement) ~= "string" then return false, "replacement must be text" end
  local unchanged, err = M.revalidate(expected)
  if not unchanged then return false, err end

  local writeScript = [[
tell application id "com.microsoft.Powerpoint"
  if not running then error "PowerPoint is not running"
  if (count of presentations) is 0 then error "No active presentation"
  set presentationValue to active presentation
  set windowValue to active window
  set currentSlide to slide of view of active window
  set selectionValue to selection of windowValue
  set textRangeValue to text range of selectionValue
  if (selection type of selectionValue) is not selection type text then error "Selection is not a text selection"
  if (text length of textRangeValue) is 0 then error "Selection is empty"
  set content of textRangeValue to ]] .. string.format("%q", replacement) .. "\n" .. [[
  return true
end tell
]]
  local result, writeErr = scriptCall(writeScript)
  if not result then return false, writeErr end
  return true
end

M.equalSnapshot = equalSnapshot

return M
