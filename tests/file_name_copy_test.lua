local alerts = {}
local timers = {}
local keyStrokes = {}
local pasteboardWrites = {}
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
      if failureMode == "setContents" then
        error("setContents failure")
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
      pasteboard.contents, pasteboard.data, pasteboard.types = nil, {}, {}
      pasteboard.changeCount = pasteboard.changeCount + 1
      return true
    end,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
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

resetClipboard()
finderSelection = { "/Users/test/first.csv", "/Users/test/folder/second.md" }
assertEqual(action.run(), true, "Finder multiple selection succeeds")
assertEqual(pasteboard.contents, "first.csv\nsecond.md", "Finder preserves selection order")

-- Cursor: path copy, basename conversion, and shortcut sequence.
resetClipboard()
frontmostName = "Cursor"
assertEqual(action.run(), true, "Cursor selection copy starts")
assertEqual(#keyStrokes, 2, "Cursor sends the Copy Path shortcut")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "selected.md", "Cursor copies basename from path")

-- Target and API boundaries.
resetClipboard()
frontmostName = "Safari"
local beforeKeys, beforeCount = #keyStrokes, pasteboard.changeCount
assertEqual(action.run(), false, "non-target application is rejected")
assertEqual(#keyStrokes, beforeKeys, "non-target application sends no pseudo-keys")
assertEqual(pasteboard.changeCount, beforeCount, "non-target application preserves clipboard")

resetClipboard()
frontmostName = "Finder"
finderSelection = {}
assertEqual(action.run(), false, "empty Finder selection is rejected")
local savedOSAScript = hs.osascript
hs.osascript = nil
local finderAPIKeys = #keyStrokes
assertEqual(action.run(), false, "missing Finder API is rejected")
assertEqual(#keyStrokes, finderAPIKeys, "missing Finder API sends no pseudo-keys")
hs.osascript = savedOSAScript
failureMode = "finderError"
assertEqual(action.run(), false, "Finder API error is rejected")
failureMode = nil

frontmostName = "Cursor"
resetClipboard()
local savedAllContentTypes = hs.pasteboard.allContentTypes
hs.pasteboard.allContentTypes = nil
local backupAPIKeys = #keyStrokes
assertEqual(action.run(), false, "missing backup API aborts before keys")
assertEqual(#keyStrokes, backupAPIKeys, "missing backup API sends no keys")
hs.pasteboard.allContentTypes = savedAllContentTypes

resetClipboard()
pasteboard.types = { { "public.utf8-plain-text" }, { "public.utf8-plain-text" } }
assertEqual(action.run(), false, "multiple clipboard items abort before keys")
assertEqual(#keyStrokes, 0, "multiple clipboard items send no keys")

resetClipboard()
failureMode = "readAllData"
assertEqual(action.run(), false, "clipboard read error aborts before keys")
assertEqual(#keyStrokes, 0, "clipboard read error sends no keys")
failureMode = "allContentTypes"
assertEqual(action.run(), false, "clipboard type error aborts before keys")
assertEqual(#keyStrokes, 0, "clipboard type error sends no keys")
failureMode = nil

resetClipboard()
pasteboard.types = { { "public.utf8-plain-text", "public.data" } }
pasteboard.data = { ["public.utf8-plain-text"] = "before" }
assertEqual(action.run(), false, "incomplete UTI snapshot aborts before keys")
assertEqual(#keyStrokes, 0, "incomplete UTI snapshot sends no keys")

resetClipboard()
frontmostName = "Finder"
finderSelection = { "/Users/test/ok.txt" }
failureMode = "setContents"
assertEqual(action.run(), false, "Finder clipboard write error is reported")
failureMode = nil

-- Format validation, timeout, restoration, and clipboard conflict.
resetClipboard()
frontmostName = "Cursor"
cursorCopyValue = "arbitrary text, not a file path"
assertEqual(action.run(), true, "malformed Cursor result starts")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "before", "malformed result restores clipboard")
assertEqual(#pasteboardWrites, 1, "malformed result performs safe restoration")

resetClipboard()
pasteboard.types = { { "public.utf8-plain-text", "public.utf16-external-plain-text", "public.data" } }
pasteboard.data = {
  ["public.utf8-plain-text"] = "before",
  ["public.utf16-external-plain-text"] = "before-utf16",
  ["public.data"] = "raw-before",
}
failureMode = "setContents"
assertEqual(action.run(), true, "Cursor final write failure starts")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "before", "final write failure restores clipboard")
assertEqual(#pasteboardWrites, 1, "final write failure restores once")
assertEqual(pasteboardWrites[1]["public.utf16-external-plain-text"], "before-utf16",
  "UTI restoration preserves non-text data")
failureMode = nil

resetClipboard()
cursorCopyResult = false
assertEqual(action.run(), true, "Cursor timeout starts")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "before", "timeout preserves clipboard")
assertEqual(#pasteboardWrites, 0, "timeout does not write without a generated path")

resetClipboard()
assertEqual(action.run(), true, "Cursor conflict starts")
setClipboard("user clipboard", "public.utf8-plain-text")
fireTimer(latestTimer())
assertEqual(pasteboard.contents, "user clipboard", "clipboard conflict preserves current value")
assertEqual(#pasteboardWrites, 0, "clipboard conflict does not restore")

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

resetClipboard()
assertEqual(action.run(), true, "Cursor delayed callback starts")
local delayedTimer = latestTimer()
action.stop()
assertEqual(delayedTimer.stopped, true, "stop cancels pending timer")
delayedTimer.callback()
assertEqual(pasteboard.contents, cursorCopyValue, "stale callback does not finish the copy")
assertEqual(#pasteboardWrites, 0, "stale callback does not write or restore")

print("file_name_copy_test: ok")
