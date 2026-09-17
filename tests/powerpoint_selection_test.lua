local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTrue(value, message)
  assert(value == true, message)
end

local function clone(values)
  local copy = {}
  for index, value in ipairs(values) do copy[index] = value end
  return copy
end

local frontmostBundle = "com.microsoft.Powerpoint"
local scriptCalls = {}
local captureFailure = false
local writeFailure = false
local postWriteFailure = false
local captureResult = {
  "Microsoft PowerPoint", "Fixture", "/tmp/fixture.pptx", "Fixture", "Fixture", 1,
  1, 101, "text selection", 3, 5, "Title", 0,
}
local postWriteResult
local writeResult = true
local writeSeen = false
local nativeWriteAttempts = 0
local nativeWriteCalls = 0

local function resetWriteState()
  captureFailure = false
  writeFailure = false
  postWriteFailure = false
  postWriteResult = nil
  writeResult = true
  writeSeen = false
  nativeWriteAttempts = 0
  nativeWriteCalls = 0
end

local frontmost = {}
function frontmost:bundleID() return frontmostBundle end
function frontmost:isFrontmost() return true end

_G.hs = {
  application = { frontmostApplication = function() return frontmost end },
  osascript = {
    applescript = function(script)
      scriptCalls[#scriptCalls + 1] = script
      if script:find("set content of textRangeValue", 1, true) then
        nativeWriteAttempts = nativeWriteAttempts + 1
        if writeFailure then return false, nil end
        writeSeen = true
        nativeWriteCalls = nativeWriteCalls + 1
        return true, writeResult
      end
      if writeSeen then
        if postWriteFailure then return false, nil end
        if postWriteResult ~= nil then return true, clone(postWriteResult) end
      end
      if captureFailure then return false, nil end
      return true, clone(captureResult)
    end,
  },
}

package.path = "./?.lua;" .. package.path
local pp = require("components.powerpoint_selection")

assertTrue(type(pp.capture) == "function", "PowerPoint module exposes capture")
assertTrue(type(pp.revalidate) == "function", "PowerPoint module exposes revalidate")
assertTrue(type(pp.writeSelection) == "function", "PowerPoint module exposes writeSelection")
assertTrue(type(pp.equalSnapshot) == "function", "PowerPoint module exposes snapshot comparison")
assertTrue(type(pp.encodeAppleScriptString) == "function", "PowerPoint module exposes safe AppleScript string encoding")

-- Title-placeholder equivalent snapshot is accepted.
local title, titleErr = pp.capture()
assertTrue(title ~= nil, titleErr or "title capture failed")
assertEqual(title.slideID, 101, "title capture slide identity")
assertEqual(title.textOffset, 3, "title capture offset")
assertEqual(title.selectedText, "Title", "title capture selection")

-- Standalone-text-box equivalent snapshot uses the same production contract.
captureResult = {
  "Microsoft PowerPoint", "Fixture", "/tmp/fixture.pptx", "Fixture", "Fixture", 1,
  1, 101, "text selection", 12, 4, "Body", 0,
}
local bodyResult = clone(captureResult)
local body, bodyErr = pp.capture()
assertTrue(body ~= nil, bodyErr or "body capture failed")
assertEqual(body.textOffset, 12, "body capture offset")
assertEqual(body.selectedText, "Body", "body capture selection")

-- Every capture identity/state component used by the accepted PowerPoint contract is fail-closed at write time.
local driftCases = {
  { "presentation name drift", 2, "Other presentation" },
  { "presentation path drift", 3, "/tmp/other.pptx" },
  { "window name drift", 4, "Other window" },
  { "window caption drift", 5, "Other caption" },
  { "window entry drift", 6, 2 },
  { "slide index drift", 7, 2 },
  { "slide id drift", 8, 202 },
  { "selection type drift", 9, "shape selection" },
  { "range offset drift", 10, 13 },
  { "range length drift", 11, 3 },
  { "selected text drift", 12, "Else" },
  { "shape range drift", 13, 1 },
}

for _, drift in ipairs(driftCases) do
  resetWriteState()
  captureResult = clone(bodyResult)
  captureResult[drift[2]] = drift[3]
  local outcome = pp.writeSelection(body, "replacement")
  assertEqual(outcome, "not_replaced", drift[1] .. " is rejected before native write")
  assertEqual(nativeWriteAttempts, 0, drift[1] .. " never dispatches native write")
end

-- Selection collapse is an explicit rejected state, not a reassertion opportunity for PowerPoint.
resetWriteState()
captureResult = clone(bodyResult)
captureResult[11] = 0
captureResult[12] = ""
local collapsedOutcome = pp.writeSelection(body, "replacement")
assertEqual(collapsedOutcome, "not_replaced", "selection collapse is rejected before native write")
assertEqual(nativeWriteAttempts, 0, "selection collapse never dispatches native write")

-- Frontmost-app drift is checked again at write time.
resetWriteState()
captureResult = clone(bodyResult)
frontmostBundle = "com.example.Other"
local frontmostOutcome = pp.writeSelection(body, "replacement")
assertEqual(frontmostOutcome, "not_replaced", "frontmost-app drift is rejected before native write")
assertEqual(nativeWriteAttempts, 0, "frontmost-app drift never dispatches native write")
frontmostBundle = "com.microsoft.Powerpoint"

-- Capture and pre-write Automation failures are fail-closed without mutation.
resetWriteState()
captureResult = clone(bodyResult)
captureFailure = true
local deniedOutcome = pp.writeSelection(body, "replacement")
assertEqual(deniedOutcome, "not_replaced", "pre-write Automation failure is not mutation eligible")
assertEqual(nativeWriteAttempts, 0, "pre-write Automation failure never dispatches native write")

-- Unexpected capture shape is fail-closed.
resetWriteState()
captureResult = { "unexpected" }
local malformed = pp.capture()
assertEqual(malformed, nil, "unexpected capture shape is rejected")

local function decodeAppleScriptStringExpression(expression)
  if type(expression) ~= "string" then return nil end
  local output = {}
  local index = 1
  local length = #expression

  local function skipSpaces()
    while index <= length and expression:sub(index, index):match("%s") do index = index + 1 end
  end

  local function consumeLiteral()
    index = index + 1
    local buffer = {}
    while index <= length do
      local ch = expression:sub(index, index)
      if ch == '"' then
        index = index + 1
        return table.concat(buffer)
      end
      if ch == "\\" then
        local nextCh = expression:sub(index + 1, index + 1)
        if nextCh == '"' or nextCh == "\\" then
          buffer[#buffer + 1] = nextCh
          index = index + 2
        else
          buffer[#buffer + 1] = ch
          index = index + 1
        end
      else
        buffer[#buffer + 1] = ch
        index = index + 1
      end
    end
    return nil
  end

  while true do
    skipSpaces()
    if index > length then break end

    local value
    local ch = expression:sub(index, index)
    if ch == '"' then
      value = consumeLiteral()
      if value == nil then return nil end
    elseif expression:sub(index, index + 4) == "quote" then
      value = '"'
      index = index + 5
    elseif expression:sub(index, index + 7) == "linefeed" then
      value = "\n"
      index = index + 8
    elseif expression:sub(index, index + 5) == "return" then
      value = "\r"
      index = index + 6
    else
      local tail = expression:sub(index)
      local characterID = tail:match("^character%s+id%s+(%d+)")
      if characterID then
        local codepoint = tonumber(characterID)
        if not codepoint or not utf8 or not utf8.char then return nil end
        value = utf8.char(codepoint)
        local matched = tail:match("^character%s+id%s+%d+")
        index = index + #matched
      else
        return nil
      end
    end
    output[#output + 1] = value

    skipSpaces()
    if index > length then break end
    if expression:sub(index, index) ~= "&" then return nil end
    index = index + 1
  end

  return table.concat(output)
end

-- Safe string transport must preserve the complete input, in order, without raw source injection.
local special = "quote \" slash \\ line1\nline2\r日本語😀"
local encoded = pp.encodeAppleScriptString(special)
assertTrue(type(encoded) == "string" and encoded ~= "", "encoded AppleScript expression is non-empty")
assertEqual(decodeAppleScriptStringExpression(encoded), special,
  "encoded AppleScript expression round-trips the complete replacement exactly")
assertTrue(encoded:find("\n", 1, true) == nil, "encoded expression contains no raw LF")
assertTrue(encoded:find(special, 1, true) == nil, "raw replacement is not embedded as one source literal")

-- Successful write verifies the postcondition and never embeds the raw replacement in source.
resetWriteState()
captureResult = {
  "Microsoft PowerPoint", "Fixture", "/tmp/fixture.pptx", "Fixture", "Fixture", 1,
  1, 101, "text selection", 20, 7, "replace", 0,
}
local current, currentErr = pp.capture()
assertTrue(current ~= nil, currentErr or "pre-write capture failed")
postWriteResult = {
  "Microsoft PowerPoint", "Fixture", "/tmp/fixture.pptx", "Fixture", "Fixture", 1,
  1, 101, "text selection", 20, #special, special, 0,
}
local outcome, outcomeReason = pp.writeSelection(current, special)
assertEqual(outcome, "verified_replaced", outcomeReason or "native write was not verified")
assertEqual(nativeWriteCalls, 1, "verified replacement dispatches exactly one native write")
local writeScript = scriptCalls[#scriptCalls - 1] or scriptCalls[#scriptCalls]
assertTrue(type(writeScript) == "string", "write script was captured")
assertTrue(writeScript:find(special, 1, true) == nil, "raw replacement is never concatenated into AppleScript source")

-- Once write dispatch is attempted, failure/unknown postcondition is terminal and must not invite fallback mutation.
resetWriteState()
captureResult = clone(bodyResult)
local writeFailureCapture = pp.capture()
writeFailure = true
local writeFailureOutcome = pp.writeSelection(writeFailureCapture, "replacement")
assertEqual(writeFailureOutcome, "replacement_dispatched_unverified",
  "write-stage Automation failure is treated as dispatched-unverified")
assertEqual(nativeWriteAttempts, 1, "write-stage Automation failure records one native write attempt")

resetWriteState()
captureResult = clone(bodyResult)
local postFailureCapture = pp.capture()
postWriteFailure = true
local postFailureOutcome = pp.writeSelection(postFailureCapture, "replacement")
assertEqual(postFailureOutcome, "replacement_dispatched_unverified",
  "postcondition Automation failure is terminal after dispatch")
assertEqual(nativeWriteCalls, 1, "postcondition failure does not cause a second native write")

resetWriteState()
captureResult = clone(bodyResult)
local unexpectedPostCapture = pp.capture()
postWriteResult = { "unexpected" }
local unexpectedPostOutcome = pp.writeSelection(unexpectedPostCapture, "replacement")
assertEqual(unexpectedPostOutcome, "replacement_dispatched_unverified",
  "unexpected postcondition result is terminal after dispatch")
assertEqual(nativeWriteCalls, 1, "unexpected postcondition result does not cause a second native write")

print("powerpoint_selection_test: ok")
