local M = {}

local POWERPOINT_BUNDLE_IDS = {
  ["com.microsoft.Powerpoint"] = true,
  ["com.microsoft.PowerPoint"] = true,
}

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
  if not bundleOK or not POWERPOINT_BUNDLE_IDS[bundleID] then
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
  if (selection type of selectionValue) is not selection type text then error "Selection is not a text selection"
  set textRangeValue to text range of selectionValue
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
  if type(snapshot.textLength) ~= "number" or snapshot.textLength <= 0
      or type(snapshot.selectedText) ~= "string" or snapshot.selectedText == "" then
    return nil, "PowerPoint selection is empty"
  end
  return snapshot
end

local function same(a, b, key)
  return a[key] == b[key]
end

local function equalSnapshot(expected, actual)
  if type(expected) ~= "table" or type(actual) ~= "table" then return false end
  for _, key in ipairs(SNAPSHOT_KEYS) do
    if not same(expected, actual, key) then return false end
  end
  return true
end

local function sameTargetAfterWrite(expected, actual, replacement)
  if type(expected) ~= "table" or type(actual) ~= "table" or type(replacement) ~= "string" then
    return false
  end
  local stableKeys = {
    "applicationName", "presentationName", "presentationPath", "windowName", "windowCaption",
    "windowEntryIndex", "slideIndex", "slideID", "selectionType", "textOffset", "shapeRangeCount",
  }
  for _, key in ipairs(stableKeys) do
    if not same(expected, actual, key) then return false end
  end
  return actual.selectedText == replacement and type(actual.textLength) == "number" and actual.textLength > 0
end

local function flushLiteral(parts, literal)
  if #literal == 0 then return end
  parts[#parts + 1] = '"' .. table.concat(literal) .. '"'
  for index = #literal, 1, -1 do literal[index] = nil end
end

function M.encodeAppleScriptString(value)
  if type(value) ~= "string" then return nil end
  if value == "" then return '""' end

  local parts = {}
  local literal = {}
  local index = 1
  while index <= #value do
    local byte = value:byte(index)
    if byte == 34 then
      flushLiteral(parts, literal)
      parts[#parts + 1] = "quote"
      index = index + 1
    elseif byte == 92 then
      flushLiteral(parts, literal)
      parts[#parts + 1] = "character id 92"
      index = index + 1
    elseif byte == 10 then
      flushLiteral(parts, literal)
      parts[#parts + 1] = "linefeed"
      index = index + 1
    elseif byte == 13 then
      flushLiteral(parts, literal)
      parts[#parts + 1] = "return"
      index = index + 1
    else
      literal[#literal + 1] = value:sub(index, index)
      index = index + 1
    end
  end
  flushLiteral(parts, literal)
  return table.concat(parts, " & ")
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
  if type(replacement) ~= "string" or replacement == "" then
    return "not_replaced", "replacement must be non-empty text"
  end

  local unchanged, revalidateErr = M.revalidate(expected)
  if not unchanged then return "not_replaced", revalidateErr end

  local encoded = M.encodeAppleScriptString(replacement)
  if not encoded then return "not_replaced", "replacement could not be encoded" end

  local writeScript = [[
tell application id "com.microsoft.Powerpoint"
  if not running then error "PowerPoint is not running"
  if (count of presentations) is 0 then error "No active presentation"
  set presentationValue to active presentation
  set windowValue to active window
  set currentSlide to slide of view of active window
  set selectionValue to selection of windowValue
  if (selection type of selectionValue) is not selection type text then error "Selection is not a text selection"
  set textRangeValue to text range of selectionValue
  if (text length of textRangeValue) is 0 then error "Selection is empty"
  set content of textRangeValue to ]] .. encoded .. "\n" .. [[
  return true
end tell
]]

  local result = scriptCall(writeScript)
  if result ~= true then
    return "replacement_dispatched_unverified", "PowerPoint native write could not be confirmed"
  end

  local afterWrite, postconditionErr = M.capture()
  if not afterWrite then
    return "replacement_dispatched_unverified", postconditionErr
  end
  if not sameTargetAfterWrite(expected, afterWrite, replacement) then
    return "replacement_dispatched_unverified", "PowerPoint native write postcondition was not verified"
  end
  return "verified_replaced", "PowerPoint native write verified"
end

M.equalSnapshot = equalSnapshot

return M
