local alerts = {}
local timers = {}
local keyStrokes = {}
local pasteboardWrites = {}
local hudNotifications = {}
local clearContentsCalls = 0
local failureMode
local frontmostName = "Finder"
local finderSelection = { "/Users/test/alpha.txt" }
local cursorCopyResult = true
local cursorCopyValue = "/Users/test/project/selected.md"
local pasteboard = {
  contents = "before",
  changeCount = 1,
  types = { { "public.utf8-plain-text" } },
  data = { ["public.utf8-plain-text"] = "before" },
}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function addTimer(_, callback)
  local timer = { callback = callback, stopped = false }
  function timer:stop()
    self.stopped = true
  end
  timers[#timers + 1] = timer
  return timer
end

local function latestTimer()
  for index = #timers, 1, -1 do
    if not timers[index].stopped then
      return timers[index]
    end
  end
end

local function fireTimer(timer)
  assert(timer and not timer.stopped, "expected a live timer")
  timer.stopped = true
  timer.callback()
end

local function setClipboard(value, uti)
  uti = uti or "public.utf8-plain-text"
  pasteboard.contents = value
  pasteboard.changeCount = pasteboard.changeCount + 1
  pasteboard.types = { { uti } }
  pasteboard.data = { [uti] = value }
end

_G.hs = {
  alert = {
    show = function(message)
      alerts[#alerts + 1] = message
    end,
  },
  application = {
    frontmostApplication = function()
      return { name = function() return frontmostName end }
    end,
  },
  osascript = {
    applescript = function()
      if failureMode == "finderError" then
        error("Finder API failure")
      end
      if failureMode == "finderReturn" then
        return false
      end
      return true, finderSelection
    end,
  },
  eventtap = {
    keyStroke = function(modifiers, key)
      if failureMode == "cursorError" then error("Cursor API failure") end
      if failureMode == "cursorReturn" then return false end
      keyStrokes[#keyStrokes + 1] = { modifiers = modifiers, key = key }
      local expectedModifiers = #keyStrokes == 1 and "cmd" or ""
      assertEqual(table.concat(modifiers, "+"), expectedModifiers, "Cursor Copy Path chord modifiers")
      assertEqual(key, (#keyStrokes == 1 and "r" or "p"), "Cursor copy path key sequence")
      if cursorCopyResult then
        setClipboard(cursorCopyValue, "public.utf8-plain-text")
      end
      return true
    end,
  },
  timer = {
    doAfter = addTimer,
    stop = function(timer) timer:stop() end,
  },
  pasteboard = {
    setContents = function(value)
      if failureMode == "setContents" or failureMode == "restoreWriteAllData"
          or failureMode == "restoreWriteAllDataFalse"
          or failureMode == "restoreClearContents"
          or failureMode == "restoreClearContentsFalse" then
        error("setContents failure")
      end
      if failureMode == "setContentsFalse" then
        return false
      end
      pasteboardWrites[#pasteboardWrites + 1] = value
      pasteboard.contents = value
      pasteboard.changeCount = pasteboard.changeCount + 1
      pasteboard.types = { { "public.utf8-plain-text" } }
      pasteboard.data = { ["public.utf8-plain-text"] = value }
      return true
    end,
    allContentTypes = function()
      if failureMode == "allContentTypes" then
        error("allContentTypes failure")
      end
      return pasteboard.types
    end,
    readAllData = function()
      if failureMode == "readAllData" then
        error("readAllData failure")
      end
      return pasteboard.data
    end,
    writeAllData = function(data)
      if failureMode == "writeAllData" or failureMode == "restoreWriteAllData" then
        error("writeAllData failure")
      end
      if failureMode == "writeAllDataFalse" or failureMode == "restoreWriteAllDataFalse" then
        return false
      end
      pasteboardWrites[#pasteboardWrites + 1] = data
      pasteboard.data = data
      pasteboard.contents = data["public.utf8-plain-text"] or data["public.utf16-external-plain-text"]
      pasteboard.changeCount = pasteboard.changeCount + 1
      pasteboard.types = { {} }
      for uti in pairs(data) do
        pasteboard.types[1][#pasteboard.types[1] + 1] = uti
      end
      return true
    end,
    getContents = function() return pasteboard.contents end,
    changeCount = function() return pasteboard.changeCount end,
    clearContents = function()
      clearContentsCalls = clearContentsCalls + 1
      if failureMode == "clearContents" or failureMode == "restoreClearContents" then
        error("clearContents failure")
      end
      if failureMode == "clearContentsFalse" or failureMode == "restoreClearContentsFalse" then
        return false
      end
      pasteboard.contents, pasteboard.data, pasteboard.types = nil, {}, {}
      pasteboard.changeCount = pasteboard.changeCount + 1
      return true
    end,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["components.hud"] = function()
  return {
    showTransient = function(message, seconds)
      hudNotifications[#hudNotifications + 1] = { message = message, seconds = seconds }
      return true
    end,
  }
end
local action = require("actions.file_name_copy")
assert(type(action.run) == "function", "file_name_copy exports run")
assert(type(action.stop) == "function", "file_name_copy exports stop")

local function resetClipboard()
  action.stop()
  pasteboard.contents = "before"
  pasteboard.changeCount = 1
  pasteboard.types = { { "public.utf8-plain-text" } }
  pasteboard.data = { ["public.utf8-plain-text"] = "before" }
  pasteboardWrites = {}
  clearContentsCalls = 0
  keyStrokes = {}
  timers = {}
  failureMode = nil
  cursorCopyResult = true
  cursorCopyValue = "/Users/test/project/selected.md"
end

-- Finder: basename conversion and selection order.
assertEqual(action.run(), true, "Finder single selection succeeds")
assertEqual(pasteboard.contents, "alpha.txt", "Finder copies basename with extension")
assertEqual(#keyStrokes, 0, "Finder does not send pseudo-keys")
assertEqual(#hudNotifications, 1, "successful Finder copy shows one HUD notification")
assertEqual(hudNotifications[1].message, "Copied", "successful Finder HUD message")
assertEqual(hudNotifications[1].seconds, 2, "successful Finder HUD duration")

resetClipboard()
finderSelection = { "/Users/test/first.csv", "/Users/test/folder/second.md" }
assertEqual(action.run(), true, "Finder multiple selection succeeds")
assertEqual(pasteboard.contents, "first.csv\nsecond.md", "Finder preserves selection order")
assertEqual(#hudNotifications, 2, "successful multiple Finder copy shows one HUD notification")
assertEqual(hudNotifications[2].message, "Copied", "successful multiple Finder HUD message")
assertEqual(hudNotifications[2].seconds, 2, "successful multiple Finder HUD duration")

-- Cursor: path copy, basename conversion, and shortcut sequence.
resetClipboard()
frontmostName = "Cursor"
assertEqual(action.run(), true, "Cursor selection copy starts")
assertEqual(#keyStrokes, 2, "Cursor sends the Copy Path shortcut")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "selected.md", "Cursor copies basename from path")
assertEqual(#hudNotifications, 3, "successful Cursor copy shows one HUD notification")
assertEqual(hudNotifications[3].message, "Copied", "successful Cursor HUD message")
assertEqual(hudNotifications[3].seconds, 2, "successful Cursor HUD duration")

resetClipboard()
frontmostName = "Cursor"
local priorNotifications = #hudNotifications
failureMode = "cursorError"
local priorAlerts = #alerts
assertEqual(action.run(), false, "Cursor API error is rejected")
assertEqual(#hudNotifications, priorNotifications, "Cursor API error has no success HUD")
assertEqual(#alerts, priorAlerts + 1, "Cursor API error shows one alert")
assertEqual(alerts[#alerts], "Cursorの選択項目を取得できませんでした。", "Cursor API error alert message")
failureMode = "cursorReturn"
priorNotifications = #hudNotifications
priorAlerts = #alerts
assertEqual(action.run(), false, "Cursor API return failure is rejected")
assertEqual(#hudNotifications, priorNotifications, "Cursor API return failure has no success HUD")
assertEqual(#alerts, priorAlerts + 1, "Cursor API return failure shows one alert")
assertEqual(alerts[#alerts], "Cursorの選択項目を取得できませんでした。", "Cursor API return failure alert message")
failureMode = nil

-- Target and API boundaries.
resetClipboard()
frontmostName = "Safari"
local beforeKeys, beforeCount = #keyStrokes, pasteboard.changeCount
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "non-target application is rejected")
assertEqual(#keyStrokes, beforeKeys, "non-target application sends no pseudo-keys")
assertEqual(pasteboard.changeCount, beforeCount, "non-target application preserves clipboard")
assertEqual(#hudNotifications, priorNotifications, "non-target application shows no success HUD")

resetClipboard()
frontmostName = "Finder"
finderSelection = {}
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "empty Finder selection is rejected")
assertEqual(#hudNotifications, priorNotifications, "empty Finder selection has no success HUD")
local savedOSAScript = hs.osascript
hs.osascript = nil
local finderAPIKeys = #keyStrokes
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "missing Finder API is rejected")
assertEqual(#keyStrokes, finderAPIKeys, "missing Finder API sends no pseudo-keys")
assertEqual(#hudNotifications, priorNotifications, "missing Finder API has no success HUD")
hs.osascript = savedOSAScript
failureMode = "finderError"
priorNotifications = #hudNotifications
local priorAlerts = #alerts
assertEqual(action.run(), false, "Finder API error is rejected")
assertEqual(#hudNotifications, priorNotifications, "Finder API error has no success HUD")
assertEqual(#alerts, priorAlerts + 1, "Finder API error shows one alert")
assertEqual(alerts[#alerts], "Finderの選択項目を取得できませんでした。", "Finder API error alert message")
failureMode = "finderReturn"
priorNotifications = #hudNotifications
priorAlerts = #alerts
assertEqual(action.run(), false, "Finder API return failure is rejected")
assertEqual(#hudNotifications, priorNotifications, "Finder API return failure has no success HUD")
assertEqual(#alerts, priorAlerts + 1, "Finder API return failure shows one alert")
assertEqual(alerts[#alerts], "Finderの選択項目を取得できませんでした。", "Finder API return failure alert message")
failureMode = nil

frontmostName = "Cursor"
resetClipboard()
local savedAllContentTypes = hs.pasteboard.allContentTypes
hs.pasteboard.allContentTypes = nil
local backupAPIKeys = #keyStrokes
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "missing backup API aborts before keys")
assertEqual(#keyStrokes, backupAPIKeys, "missing backup API sends no keys")
assertEqual(#hudNotifications, priorNotifications, "missing backup API has no success HUD")
hs.pasteboard.allContentTypes = savedAllContentTypes

resetClipboard()
pasteboard.types = { { "public.utf8-plain-text" }, { "public.utf8-plain-text" } }
assertEqual(action.run(), false, "multiple clipboard items abort before keys")
assertEqual(#keyStrokes, 0, "multiple clipboard items send no keys")
assertEqual(#hudNotifications, priorNotifications, "multiple clipboard items have no success HUD")

resetClipboard()
failureMode = "readAllData"
assertEqual(action.run(), false, "clipboard read error aborts before keys")
assertEqual(#keyStrokes, 0, "clipboard read error sends no keys")
assertEqual(#hudNotifications, priorNotifications, "clipboard read error has no success HUD")
failureMode = "allContentTypes"
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "clipboard type error aborts before keys")
assertEqual(#keyStrokes, 0, "clipboard type error sends no keys")
assertEqual(#hudNotifications, priorNotifications, "clipboard type error has no success HUD")
failureMode = nil

resetClipboard()
pasteboard.types = { { "public.utf8-plain-text", "public.data" } }
pasteboard.data = { ["public.utf8-plain-text"] = "before" }
assertEqual(action.run(), false, "incomplete UTI snapshot aborts before keys")
assertEqual(#keyStrokes, 0, "incomplete UTI snapshot sends no keys")
assertEqual(#hudNotifications, priorNotifications, "incomplete UTI snapshot has no success HUD")

resetClipboard()
frontmostName = "Finder"
finderSelection = { "/Users/test/ok.txt" }
failureMode = "setContents"
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "Finder clipboard write error is reported")
assertEqual(#hudNotifications, priorNotifications, "Finder clipboard write error has no success HUD")
assertEqual(alerts[#alerts], "ファイル名をクリップボードへコピーできませんでした。", "Finder clipboard write error alert message")
failureMode = "setContentsFalse"
priorNotifications = #hudNotifications
priorAlerts = #alerts
assertEqual(action.run(), false, "Finder clipboard false write failure is reported")
assertEqual(#hudNotifications, priorNotifications, "Finder clipboard false write failure has no success HUD")
assertEqual(#alerts, priorAlerts + 1, "Finder clipboard false write failure shows one alert")
assertEqual(alerts[#alerts], "ファイル名をクリップボードへコピーできませんでした。", "Finder clipboard false write failure alert message")
failureMode = nil

-- Format validation, timeout, restoration, and clipboard conflict.
resetClipboard()
frontmostName = "Cursor"
cursorCopyValue = "arbitrary text, not a file path"
assertEqual(action.run(), true, "malformed Cursor result starts")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "before", "malformed result restores clipboard")
assertEqual(#pasteboardWrites, 1, "malformed result performs safe restoration")
assertEqual(#hudNotifications, priorNotifications, "malformed result has no success HUD")

resetClipboard()
pasteboard.types = { { "public.utf8-plain-text", "public.utf16-external-plain-text", "public.data" } }
pasteboard.data = {
  ["public.utf8-plain-text"] = "before",
  ["public.utf16-external-plain-text"] = "before-utf16",
  ["public.data"] = "raw-before",
}
failureMode = "setContents"
priorAlerts = #alerts
assertEqual(action.run(), true, "Cursor final write failure starts")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "before", "final write failure restores clipboard")
assertEqual(#pasteboardWrites, 1, "final write failure restores once")
assertEqual(pasteboardWrites[1]["public.utf16-external-plain-text"], "before-utf16",
  "UTI restoration preserves non-text data")
assertEqual(#hudNotifications, priorNotifications, "final write failure has no success HUD")
assertEqual(#alerts, priorAlerts + 1, "final write failure shows one alert")
assertEqual(alerts[#alerts], "ファイル名をクリップボードへコピーできませんでした。", "final write failure alert message")

resetClipboard()
failureMode = "setContentsFalse"
priorAlerts = #alerts
assertEqual(action.run(), true, "Cursor final false write failure starts")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "before", "final false write failure restores clipboard")
assertEqual(#pasteboardWrites, 1, "final false write failure restores once")
assertEqual(#hudNotifications, priorNotifications, "final false write failure has no success HUD")
assertEqual(#alerts, priorAlerts + 1, "final false write failure shows one alert")
assertEqual(alerts[#alerts], "ファイル名をクリップボードへコピーできませんでした。", "final false write failure alert message")
failureMode = nil

for _, mode in ipairs({ "restoreWriteAllData", "restoreWriteAllDataFalse" }) do
  resetClipboard()
  local priorRestoreNotifications = #hudNotifications
  priorAlerts = #alerts
  failureMode = mode
  assertEqual(action.run(), true, "Cursor restoration " .. mode .. " starts")
  fireTimer(latestTimer())
  assertEqual(pasteboard.contents, cursorCopyValue, "failed restoration preserves failed final clipboard")
  assertEqual(#hudNotifications, priorRestoreNotifications, "failed restoration has no success HUD")
  assertEqual(#alerts, priorAlerts + 1, "failed restoration shows one alert")
  assertEqual(alerts[#alerts], "クリップボードを復元できませんでした。", "failed restoration alert message")
end

resetClipboard()
cursorCopyResult = false
assertEqual(action.run(), true, "Cursor timeout starts")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "before", "timeout preserves clipboard")
assertEqual(#pasteboardWrites, 0, "timeout does not write without a generated path")
assertEqual(#hudNotifications, priorNotifications, "timeout has no success HUD")

resetClipboard()
assertEqual(action.run(), true, "Cursor conflict starts")
setClipboard("user clipboard", "public.utf8-plain-text")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "user clipboard", "clipboard conflict preserves current value")
assertEqual(#pasteboardWrites, 0, "clipboard conflict does not restore")
assertEqual(#hudNotifications, priorNotifications, "clipboard conflict has no success HUD")

resetClipboard()
pasteboard.contents = nil
pasteboard.changeCount = 1
pasteboard.types = {}
pasteboard.data = {}
failureMode = "setContents"
assertEqual(action.run(), true, "empty clipboard final write failure starts")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, nil, "clearContents restores empty clipboard")
assertEqual(clearContentsCalls, 1, "empty restoration uses clearContents")
assertEqual(#hudNotifications, priorNotifications, "empty clipboard final write failure has no success HUD")
assertEqual(alerts[#alerts], "ファイル名をクリップボードへコピーできませんでした。", "empty clipboard final write failure alert message")

for _, mode in ipairs({ "restoreClearContents", "restoreClearContentsFalse" }) do
  resetClipboard()
  pasteboard.contents = nil
  pasteboard.changeCount = 1
  pasteboard.types = {}
  pasteboard.data = {}
  local priorEmptyRestoreNotifications = #hudNotifications
  priorAlerts = #alerts
  failureMode = mode
  assertEqual(action.run(), true, "empty clipboard " .. mode .. " starts")
  fireTimer(latestTimer())
  assertEqual(pasteboard.contents, cursorCopyValue, "failed empty restoration preserves failed final clipboard")
  assertEqual(#hudNotifications, priorEmptyRestoreNotifications, "failed empty restoration has no success HUD")
  assertEqual(#alerts, priorAlerts + 1, "failed empty restoration shows one alert")
  assertEqual(alerts[#alerts], "クリップボードを復元できませんでした。", "failed empty restoration alert message")
end

resetClipboard()
assertEqual(action.run(), true, "Cursor delayed callback starts")
local delayedTimer = latestTimer()
action.stop()
assertEqual(delayedTimer.stopped, true, "stop cancels pending timer")
delayedTimer.callback()
assertEqual(pasteboard.contents, cursorCopyValue, "stale callback does not finish the copy")
assertEqual(#pasteboardWrites, 0, "stale callback does not write or restore")

print("file_name_copy_test: ok")
