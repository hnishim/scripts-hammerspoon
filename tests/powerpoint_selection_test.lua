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
local scriptFailure = false
local captureResult = {
  "Microsoft PowerPoint", "Fixture", "/tmp/fixture.pptx", "Fixture", "Fixture", 1,
  1, 101, "text selection", 3, 5, "Title", 0,
}
local postWriteResult
local writeResult = true
local writeSeen = false

local frontmost = {}
function frontmost:bundleID() return frontmostBundle end
function frontmost:isFrontmost() return true end

_G.hs = {
  application = { frontmostApplication = function() return frontmost end },
  osascript = {
    applescript = function(script)
      scriptCalls[#scriptCalls + 1] = script
      if scriptFailure then return false, nil end
      if script:find("set content of textRangeValue", 1, true) then
        writeSeen = true
        return true, writeResult
      end
      if writeSeen and postWriteResult then return true, clone(postWriteResult) end
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
local body, bodyErr = pp.capture()
assertTrue(body ~= nil, bodyErr or "body capture failed")
assertEqual(body.textOffset, 12, "body capture offset")
assertEqual(body.selectedText, "Body", "body capture selection")

-- Any snapshot drift rejects mutation before native write.
local expected = body
captureResult = {
  "Microsoft PowerPoint", "Fixture", "/tmp/fixture.pptx", "Fixture", "Fixture", 1,
  1, 101, "text selection", 13, 4, "Body", 0,
}
local matches = pp.revalidate(expected)
assertEqual(matches, false, "range drift is rejected")
assertEqual(writeSeen, false, "revalidation failure does not write")

-- Frontmost-app drift is fail-closed without asking PowerPoint to mutate.
frontmostBundle = "com.example.Other"
local beforeScripts = #scriptCalls
local missing = pp.capture()
assertEqual(missing, nil, "non-frontmost PowerPoint capture is rejected")
assertEqual(#scriptCalls, beforeScripts, "frontmost-app rejection does not run AppleScript")
frontmostBundle = "com.microsoft.Powerpoint"

-- Unexpected AppleScript shape and Automation failure are fail-closed.
captureResult = { "unexpected" }
local malformed = pp.capture()
assertEqual(malformed, nil, "unexpected capture shape is rejected")
scriptFailure = true
local denied = pp.capture()
assertEqual(denied, nil, "Automation failure is rejected")
scriptFailure = false

-- Safe string transport must preserve quotes, backslashes, CR/LF, Japanese and emoji without raw line injection.
local special = "quote \" slash \\ line1\nline2\r日本語😀"
local encoded = pp.encodeAppleScriptString(special)
assertTrue(type(encoded) == "string" and encoded ~= "", "encoded AppleScript expression is non-empty")
assertTrue(encoded:find("linefeed", 1, true) ~= nil, "LF is encoded as an AppleScript expression")
assertTrue(encoded:find("return", 1, true) ~= nil, "CR is encoded as an AppleScript expression")
assertTrue(encoded:find("日本語😀", 1, true) ~= nil, "Unicode content is preserved")
assertTrue(encoded:find("\n", 1, true) == nil, "encoded expression contains no raw LF")

captureResult = {
  "Microsoft PowerPoint", "Fixture", "/tmp/fixture.pptx", "Fixture", "Fixture", 1,
  1, 101, "text selection", 20, 7, "replace", 0,
}
postWriteResult = {
  "Microsoft PowerPoint", "Fixture", "/tmp/fixture.pptx", "Fixture", "Fixture", 1,
  1, 101, "text selection", 20, #special, special, 0,
}
writeResult = special
writeSeen = false
local current, currentErr = pp.capture()
assertTrue(current ~= nil, currentErr or "pre-write capture failed")
local outcome, outcomeReason = pp.writeSelection(current, special)
assertEqual(outcome, "verified_replaced", outcomeReason or "native write was not verified")
assertTrue(writeSeen, "verified replacement dispatches native write")
local writeScript = scriptCalls[#scriptCalls - 1] or scriptCalls[#scriptCalls]
assertTrue(type(writeScript) == "string", "write script was captured")
assertTrue(writeScript:find(special, 1, true) == nil, "raw replacement is never concatenated into AppleScript source")

print("powerpoint_selection_test: ok")
