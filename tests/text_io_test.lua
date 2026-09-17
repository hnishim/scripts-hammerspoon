local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertNil(actual, message)
  assert(actual == nil, message .. ": expected nil, got " .. tostring(actual))
end

package.path = "./?.lua;./?/init.lua;" .. package.path
local textIO = require("components.text_io")

local bundleID = "com.example.Editor"
local swiftCalls = {}
local powerPointCalls = {}
local replacementCalls = {}

local function replacementHandle(name)
  return function(replacement, callback)
    replacementCalls[#replacementCalls + 1] = { name = name, replacement = replacement }
    callback({ outcome = "verified_replaced" })
    return true
  end
end

local swiftBackend = {
  capture = function(mode, callback)
    swiftCalls[#swiftCalls + 1] = mode
    callback({
      status = "selected",
      text = "swift-selection",
      source = "ax_selected_text",
      replace = replacementHandle("swift"),
    })
    return true
  end,
}

local powerPointBackend = {
  capture = function(mode, callback)
    powerPointCalls[#powerPointCalls + 1] = mode
    callback({
      status = "selected",
      text = "powerpoint-selection",
      source = "powerpoint",
      replace = replacementHandle("powerpoint"),
    })
    return true
  end,
}

local io = textIO.new({
  currentBundleID = function() return bundleID end,
  swiftBackend = swiftBackend,
  powerPointBackend = powerPointBackend,
})

-- Normal read uses the Swift-backed shared selection source and never exposes mutation capability.
do
  local result
  assert(io.capture("read", function(value) result = value end) ~= false, "normal read starts")
  assertEqual(#swiftCalls, 1, "normal read uses Swift backend once")
  assertEqual(swiftCalls[1], "read", "normal read forwards read mode")
  assertEqual(#powerPointCalls, 0, "normal read does not use PowerPoint backend")
  assertEqual(result.status, "selected", "normal read status")
  assertEqual(result.text, "swift-selection", "normal read text")
  assertEqual(result.source, "ax_selected_text", "normal read source")
  assertNil(result.replace, "read result does not expose replacement handle")
end

-- Normal replace uses the same public entry, retains replacement capability, and delegates write-back to the backend.
do
  local result
  assert(io.capture("replace", function(value) result = value end) ~= false, "normal replace starts")
  assertEqual(#swiftCalls, 2, "normal replace uses Swift backend")
  assertEqual(swiftCalls[2], "replace", "normal replace forwards replace mode")
  assertEqual(result.status, "selected", "normal replace status")
  assertEqual(result.text, "swift-selection", "normal replace text")
  assert(type(result.replace) == "function", "replace result exposes one write-back handle")

  local outcome
  assert(result.replace("変換後", function(value) outcome = value end) ~= false, "normal replacement starts")
  assertEqual(replacementCalls[#replacementCalls].name, "swift", "normal write-back stays on Swift backend")
  assertEqual(replacementCalls[#replacementCalls].replacement, "変換後", "normal replacement payload")
  assertEqual(outcome.outcome, "verified_replaced", "normal replacement outcome")
end

-- PowerPoint is selected behind the same public entry for both read and replace.
do
  bundleID = "com.microsoft.PowerPoint"
  local readResult
  assert(io.capture("read", function(value) readResult = value end) ~= false, "PowerPoint read starts")
  assertEqual(powerPointCalls[#powerPointCalls], "read", "PowerPoint read uses dedicated backend")
  assertEqual(readResult.text, "powerpoint-selection", "PowerPoint read text")
  assertNil(readResult.replace, "PowerPoint read does not expose write-back")

  local replaceResult
  assert(io.capture("replace", function(value) replaceResult = value end) ~= false, "PowerPoint replace starts")
  assertEqual(powerPointCalls[#powerPointCalls], "replace", "PowerPoint replace uses dedicated backend")
  assert(type(replaceResult.replace) == "function", "PowerPoint replace retains dedicated write-back handle")
  replaceResult.replace("結果", function() end)
  assertEqual(replacementCalls[#replacementCalls].name, "powerpoint", "PowerPoint write-back stays on dedicated backend")
end

-- Backend result states are preserved without turning acquisition failure into no-selection.
do
  bundleID = "com.example.Editor"
  local statuses = { "none", "unavailable", "error" }
  for _, status in ipairs(statuses) do
    swiftBackend.capture = function(mode, callback)
      swiftCalls[#swiftCalls + 1] = mode
      callback({ status = status })
      return true
    end
    local result
    io.capture("read", function(value) result = value end)
    assertEqual(result.status, status, "public status remains distinct: " .. status)
    assertNil(result.text, "terminal acquisition state has no text: " .. status)
    assertNil(result.replace, "terminal acquisition state has no replacement handle: " .. status)
  end
end

-- Invalid modes fail before selecting any backend.
do
  local beforeSwift = #swiftCalls
  local beforePowerPoint = #powerPointCalls
  local callbackCalled = false
  assertEqual(io.capture("unknown", function() callbackCalled = true end), false, "invalid mode is rejected")
  assertEqual(callbackCalled, false, "invalid mode does not invoke callback")
  assertEqual(#swiftCalls, beforeSwift, "invalid mode does not use Swift backend")
  assertEqual(#powerPointCalls, beforePowerPoint, "invalid mode does not use PowerPoint backend")
end

print("text_io_test: ok")
