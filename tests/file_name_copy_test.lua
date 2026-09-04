local alerts = {}
local keyStrokes = {}
local performedActions = {}
local pasteboardWrites = {}
local hudNotifications = {}
local clearContentsCalls = 0
local timerCalls = 0
local failureMode
local frontmostName = "Finder"
local finderSelection = { "/Users/test/alpha.txt" }
local cursorFocus = "editor"
local cursorActiveFile = "/Users/test/project/active.lua"
local cursorExplorerFile = "/Users/test/project/lib/module.lua"
local cursorExplorerFolder = "/Users/test/project/src"
local cursorClipboardConflict = false
local quickOpenOpened = false
local cursorAXModel

local pasteboard = {
  contents = "before",
  changeCount = 1,
  types = { { "public.utf8-plain-text" } },
  data = { ["public.utf8-plain-text"] = "before" },
}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message,
    tostring(expected), tostring(actual)))
end

local function setClipboard(value, uti)
  uti = uti or "public.utf8-plain-text"
  pasteboard.contents = value
  pasteboard.changeCount = pasteboard.changeCount + 1
  pasteboard.types = { { uti } }
  pasteboard.data = { [uti] = value }
end

local function makeAXElement(attributes, children)
  local element = {}
  function element:attributeValue(attribute)
    if attribute == "AXChildren" then return children or {} end
    return attributes[attribute]
  end
  function element:performAction(action)
    performedActions[#performedActions + 1] = action
    return false
  end
  return element
end

local function buildCursorModel()
  local focused
  if cursorFocus == "editor" then
    focused = makeAXElement({ AXRole = "AXTextArea" })
  elseif cursorFocus == "terminal" then
    focused = makeAXElement({ AXRole = "AXTextField" })
  elseif cursorFocus == "unknown" then
    focused = makeAXElement({ AXRole = "AXGroup" })
  elseif cursorFocus == "non-explorer-row" then
    local panel = makeAXElement({ AXRole = "AXGroup", AXTitle = "Terminal" })
    focused = makeAXElement({
      AXRole = "AXRow",
      AXTitle = "terminal output",
      AXURL = "/Users/test/project/wrong-row-selection.txt",
      AXParent = panel,
    })
  elseif cursorFocus == "non-explorer-outline" then
    focused = makeAXElement({ AXRole = "AXOutline", AXTitle = "Output" })
  elseif cursorFocus == "explorer-file" then
    local explorerPane = makeAXElement({ AXRole = "AXOutline", AXTitle = "Files Explorer" })
    focused = makeAXElement({
      AXRole = "AXRow",
      AXTitle = "module.lua",
      AXURL = cursorExplorerFile,
      AXParent = explorerPane,
    })
  elseif cursorFocus == "explorer-folder" then
    local explorerPane = makeAXElement({ AXRole = "AXOutline", AXTitle = "Files Explorer" })
    focused = makeAXElement({
      AXRole = "AXRow",
      AXTitle = "src",
      AXURL = cursorExplorerFolder,
      AXParent = explorerPane,
    })
  elseif cursorFocus == "explorer-outline" then
    local firstRow = makeAXElement({
      AXRole = "AXRow",
      AXTitle = "first.lua",
      AXURL = "/Users/test/project/first.lua",
    })
    local selectedRow = makeAXElement({
      AXRole = "AXRow",
      AXTitle = "module.lua",
      AXURL = cursorExplorerFile,
    })
    focused = makeAXElement({
      AXRole = "AXOutline",
      AXTitle = "Files Explorer",
      AXSelectedRows = { selectedRow },
    }, { firstRow, selectedRow })
  end

  local window = makeAXElement({
    AXRole = "AXWindow",
    AXDocument = "file://" .. cursorActiveFile,
  })
  local appElement = makeAXElement({
    AXFocusedWindow = window,
    AXMainWindow = window,
    AXWindows = { window },
  }, { window })
  cursorAXModel = { appElement = appElement, focused = focused }
  return focused
end

_G.hs = {
  alert = {
    show = function(message)
      alerts[#alerts + 1] = message
    end,
  },
  application = {
    frontmostApplication = function()
      return {
        name = function() return frontmostName end,
        pid = function() return 123 end,
      }
    end,
  },
  axuielement = {
    applicationElement = function(pid)
      assertEqual(pid, 123, "Cursor AX application uses the frontmost PID")
      assert(cursorAXModel, "Cursor AX model is initialized by the focused element query")
      return cursorAXModel.appElement
    end,
    systemWideElement = function()
      if failureMode == "cursorError" then error("Cursor API failure") end
      if failureMode == "cursorReturn" then return nil end
      local focused = buildCursorModel()
      if cursorClipboardConflict then
        cursorClipboardConflict = false
        setClipboard("/Users/external/important.txt")
      end
      return {
        attributeValue = function(_, attribute)
          focusQueries[#focusQueries + 1] = attribute
          if attribute ~= "AXFocusedUIElement" then return nil end
          return focused
        end,
      }
    end,
  },
  osascript = {
    applescript = function()
      if failureMode == "finderError" then error("Finder API failure") end
      if failureMode == "finderReturn" then return false end
      return true, finderSelection
    end,
  },
  eventtap = {
    keyStroke = function(modifiers, key)
      keyStrokes[#keyStrokes + 1] = { modifiers = modifiers, key = key }
      if table.concat(modifiers, "+") == "cmd" and key == "r" then
        quickOpenOpened = true
      end
      return true
    end,
  },
  timer = {
    doAfter = function()
      timerCalls = timerCalls + 1
      error("Cursor path must not schedule a timer")
    end,
  },
  pasteboard = {
    setContents = function(value)
      if failureMode == "setContents" or failureMode == "restoreWriteAllData"
          or failureMode == "restoreWriteAllDataFalse"
          or failureMode == "restoreClearContents"
          or failureMode == "restoreClearContentsFalse" then
        if failureMode == "setContentsFalse" then return false end
        error("setContents failure")
      end
      if failureMode == "setContentsFalse" then return false end
      pasteboardWrites[#pasteboardWrites + 1] = value
      pasteboard.contents = value
      pasteboard.changeCount = pasteboard.changeCount + 1
      pasteboard.types = { { "public.utf8-plain-text" } }
      pasteboard.data = { ["public.utf8-plain-text"] = value }
      return true
    end,
    allContentTypes = function()
      if failureMode == "allContentTypes" then error("allContentTypes failure") end
      return pasteboard.types
    end,
    readAllData = function()
      if failureMode == "readAllData" then error("readAllData failure") end
      return pasteboard.data
    end,
    writeAllData = function(data)
      if failureMode == "restoreWriteAllData" then error("writeAllData failure") end
      if failureMode == "restoreWriteAllDataFalse" then return false end
      pasteboardWrites[#pasteboardWrites + 1] = data
      pasteboard.data = data
      pasteboard.contents = data["public.utf8-plain-text"]
        or data["public.utf16-external-plain-text"]
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
      if failureMode == "restoreClearContents" then error("clearContents failure") end
      if failureMode == "restoreClearContentsFalse" then return false end
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
  performedActions = {}
  timerCalls = 0
  failureMode = nil
  cursorFocus = "editor"
  cursorActiveFile = "/Users/test/project/active.lua"
  cursorExplorerFile = "/Users/test/project/lib/module.lua"
  cursorExplorerFolder = "/Users/test/project/src"
  cursorClipboardConflict = false
  quickOpenOpened = false
  focusQueries = {}
  cursorAXModel = nil
end

local function assertCursorDirect(expectedName, description)
  assertEqual(focusQueries[1], "AXFocusedUIElement",
    description .. " reads Accessibility focus")
  assertEqual(#focusQueries, 1, description .. " reads focus exactly once")
  assertEqual(timerCalls, 0, description .. " does not schedule a timer")
  assertEqual(#performedActions, 0, description .. " performs no AX menu action")
  assertEqual(#keyStrokes, 0, description .. " sends no pseudo-keys")
  assertEqual(quickOpenOpened, false, description .. " does not open Quick Open")
  assertEqual(#pasteboardWrites, 1, description .. " writes to the clipboard exactly once")
  assertEqual(pasteboardWrites[1], expectedName,
    description .. " writes only the basename")
  assertEqual(pasteboard.contents, expectedName,
    description .. " copies only the basename")
end

-- Finder: basename conversion and selection order.
assertEqual(action.run(), true, "Finder single selection succeeds")
assertEqual(pasteboard.contents, "alpha.txt", "Finder copies basename with extension")
assertEqual(#keyStrokes, 0, "Finder does not send pseudo-keys")
assertEqual(#hudNotifications, 1, "successful Finder copy shows one HUD notification")

resetClipboard()
finderSelection = { "/Users/test/first.csv", "/Users/test/folder/second.md" }
assertEqual(action.run(), true, "Finder multiple selection succeeds")
assertEqual(pasteboard.contents, "first.csv\nsecond.md", "Finder preserves selection order")
assertEqual(#hudNotifications, 2, "successful multiple Finder copy shows one HUD notification")

-- Cursor Editor and Terminal: all non-Explorer focus uses the active window document.
resetClipboard()
frontmostName = "Cursor"
cursorFocus = "editor"
cursorActiveFile = "/Users/test/project/active.lua"
local priorNotifications = #hudNotifications
assertEqual(action.run(), true, "Cursor Editor copy succeeds")
assertCursorDirect("active.lua", "Cursor Editor")
assertEqual(#hudNotifications, priorNotifications + 1, "Cursor Editor shows one HUD")

resetClipboard()
cursorFocus = "terminal"
cursorActiveFile = "/Users/test/project/scripts/build.sh"
assertEqual(action.run(), true, "Cursor Terminal copy succeeds")
assertCursorDirect("build.sh", "Cursor Terminal")

resetClipboard()
cursorFocus = "unknown"
cursorActiveFile = "/Users/test/project/docs/README.md"
assertEqual(action.run(), true, "Cursor non-Explorer focus uses Active File")
assertCursorDirect("README.md", "Cursor non-Explorer boundary")

for _, focus in ipairs({ "non-explorer-row", "non-explorer-outline" }) do
  resetClipboard()
  cursorFocus = focus
  cursorActiveFile = "/Users/test/project/panel-active.lua"
  assertEqual(action.run(), true, "Cursor " .. focus .. " uses Active File")
  assertCursorDirect("panel-active.lua", "Cursor " .. focus)
end

-- Cursor Explorer: selected file and folder use the focused row's path.
resetClipboard()
cursorFocus = "explorer-file"
assertEqual(action.run(), true, "Cursor Explorer file copy succeeds")
assertCursorDirect("module.lua", "Cursor Explorer file")

resetClipboard()
cursorFocus = "explorer-folder"
assertEqual(action.run(), true, "Cursor Explorer folder copy succeeds")
assertCursorDirect("src", "Cursor Explorer folder")

resetClipboard()
cursorFocus = "explorer-outline"
assertEqual(action.run(), true, "Cursor Explorer outline uses its selected row")
assertCursorDirect("module.lua", "Cursor Explorer outline selected row")

-- The Editor/Explorer boundary must use the focused context, not a stale value.
resetClipboard()
cursorFocus = "editor"
cursorActiveFile = "/Users/test/project/docs/README.md"
cursorExplorerFolder = "/Users/test/project/other"
assertEqual(action.run(), true, "Cursor Editor boundary copy succeeds")
assertCursorDirect("README.md", "Cursor Editor boundary")

resetClipboard()
cursorFocus = "explorer-folder"
cursorExplorerFolder = "/Users/test/project/other"
cursorActiveFile = "/Users/test/project/docs/README.md"
assertEqual(action.run(), true, "Cursor Explorer boundary copy succeeds")
assertCursorDirect("other", "Cursor Explorer boundary")

-- Focus or path acquisition failures leave the clipboard untouched.
resetClipboard()
cursorFocus = "missing"
local missingFocusChangeCount = pasteboard.changeCount
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "Cursor missing focus is rejected")
assertEqual(pasteboard.contents, "before", "Cursor missing focus preserves clipboard")
assertEqual(pasteboard.changeCount, missingFocusChangeCount,
  "Cursor missing focus preserves changeCount")
assertEqual(#hudNotifications, priorNotifications, "Cursor missing focus has no HUD")
assertEqual(timerCalls, 0, "Cursor missing focus does not schedule a timer")

resetClipboard()
cursorFocus = "explorer-file"
cursorExplorerFile = nil
local missingPathChangeCount = pasteboard.changeCount
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "Cursor Explorer missing path is rejected")
assertEqual(pasteboard.changeCount, missingPathChangeCount,
  "Cursor Explorer missing path preserves clipboard")
assertEqual(#hudNotifications, priorNotifications, "Cursor Explorer missing path has no HUD")

for _, mode in ipairs({ "cursorError", "cursorReturn" }) do
  resetClipboard()
  failureMode = mode
  local priorAlerts = #alerts
  local beforeContents = pasteboard.contents
  local beforeChangeCount = pasteboard.changeCount
  priorNotifications = #hudNotifications
  assertEqual(action.run(), false, "Cursor API " .. mode .. " is rejected")
  assertEqual(pasteboard.contents, beforeContents,
    "Cursor API " .. mode .. " preserves clipboard contents")
  assertEqual(pasteboard.changeCount, beforeChangeCount,
    "Cursor API " .. mode .. " preserves clipboard changeCount")
  assertEqual(#hudNotifications, priorNotifications,
    "Cursor API " .. mode .. " has no success HUD")
  assertEqual(#alerts, priorAlerts + 1, "Cursor API " .. mode .. " shows one alert")
end

-- Target and API boundaries.
resetClipboard()
frontmostName = "Safari"
local beforeCount = pasteboard.changeCount
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "non-target application is rejected")
assertEqual(#keyStrokes, 0, "non-target application sends no pseudo-keys")
assertEqual(pasteboard.changeCount, beforeCount, "non-target application preserves clipboard")
assertEqual(#hudNotifications, priorNotifications, "non-target application shows no HUD")

resetClipboard()
frontmostName = "Finder"
finderSelection = {}
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "empty Finder selection is rejected")
assertEqual(#hudNotifications, priorNotifications, "empty Finder selection has no HUD")

local savedOSAScript = hs.osascript
hs.osascript = nil
resetClipboard()
frontmostName = "Finder"
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "missing Finder API is rejected")
assertEqual(#hudNotifications, priorNotifications, "missing Finder API has no HUD")
hs.osascript = savedOSAScript

for _, mode in ipairs({ "finderError", "finderReturn" }) do
  resetClipboard()
  frontmostName = "Finder"
  failureMode = mode
  local priorAlerts = #alerts
  priorNotifications = #hudNotifications
  assertEqual(action.run(), false, "Finder API " .. mode .. " is rejected")
  assertEqual(#hudNotifications, priorNotifications, "Finder API " .. mode .. " has no HUD")
  assertEqual(#alerts, priorAlerts + 1, "Finder API " .. mode .. " shows one alert")
end

resetClipboard()
frontmostName = "Cursor"
local savedAllContentTypes = hs.pasteboard.allContentTypes
hs.pasteboard.allContentTypes = nil
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "missing backup API aborts before Cursor access")
assertEqual(#hudNotifications, priorNotifications, "missing backup API has no HUD")
hs.pasteboard.allContentTypes = savedAllContentTypes

resetClipboard()
pasteboard.types = { { "public.utf8-plain-text" }, { "public.utf8-plain-text" } }
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "multiple clipboard items abort safely")
assertEqual(#hudNotifications, priorNotifications, "multiple clipboard items have no HUD")

for _, mode in ipairs({ "readAllData", "allContentTypes" }) do
  resetClipboard()
  frontmostName = "Cursor"
  failureMode = mode
  priorNotifications = #hudNotifications
  assertEqual(action.run(), false, "clipboard " .. mode .. " failure aborts safely")
  assertEqual(#hudNotifications, priorNotifications, "clipboard " .. mode .. " failure has no HUD")
end

-- Invalid paths never become a successful clipboard value.
resetClipboard()
frontmostName = "Cursor"
cursorActiveFile = "arbitrary text, not a file path"
local malformedChangeCount = pasteboard.changeCount
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "malformed Cursor document is rejected")
assertEqual(pasteboard.contents, "before", "malformed Cursor document preserves clipboard")
assertEqual(pasteboard.changeCount, malformedChangeCount,
  "malformed Cursor document preserves changeCount")
assertEqual(#hudNotifications, priorNotifications, "malformed Cursor document has no HUD")

-- A failed final write restores all original UTI data safely.
resetClipboard()
frontmostName = "Cursor"
pasteboard.types = { { "public.utf8-plain-text", "public.utf16-external-plain-text", "public.data" } }
pasteboard.data = {
  ["public.utf8-plain-text"] = "before",
  ["public.utf16-external-plain-text"] = "before-utf16",
  ["public.data"] = "raw-before",
}
failureMode = "setContents"
local beforeData = pasteboard.data
priorNotifications = #hudNotifications
local priorAlerts = #alerts
assertEqual(action.run(), false, "Cursor final write failure is reported")
assertEqual(pasteboard.contents, "before", "final write failure restores clipboard")
assertEqual(#pasteboardWrites, 1, "final write failure restores once")
assertEqual(pasteboardWrites[1]["public.utf8-plain-text"], beforeData["public.utf8-plain-text"],
  "UTI restoration preserves plain text data")
assertEqual(pasteboardWrites[1]["public.utf16-external-plain-text"],
  beforeData["public.utf16-external-plain-text"], "UTI restoration preserves non-text data")
assertEqual(pasteboardWrites[1]["public.data"], beforeData["public.data"],
  "UTI restoration preserves raw data")
assertEqual(#hudNotifications, priorNotifications, "final write failure has no HUD")
assertEqual(#alerts, priorAlerts + 1, "final write failure shows one alert")

resetClipboard()
frontmostName = "Cursor"
pasteboard.types = { { "public.utf8-plain-text", "public.utf16-external-plain-text", "public.data" } }
pasteboard.data = {
  ["public.utf8-plain-text"] = "before",
  ["public.utf16-external-plain-text"] = "before-utf16",
  ["public.data"] = "raw-before",
}
failureMode = "setContentsFalse"
priorNotifications = #hudNotifications
priorAlerts = #alerts
assertEqual(action.run(), false, "Cursor false final write failure is reported")
assertEqual(pasteboard.contents, "before", "false final write failure restores clipboard")
assertEqual(#pasteboardWrites, 1, "false final write failure restores once")
assertEqual(pasteboardWrites[1]["public.utf8-plain-text"], "before",
  "false final write preserves plain text data")
assertEqual(pasteboardWrites[1]["public.utf16-external-plain-text"], "before-utf16",
  "false final write preserves non-text data")
assertEqual(pasteboardWrites[1]["public.data"], "raw-before",
  "false final write preserves raw data")
assertEqual(#hudNotifications, priorNotifications, "false final write has no HUD")
assertEqual(#alerts, priorAlerts + 1, "false final write shows one alert")

for _, mode in ipairs({ "restoreWriteAllData", "restoreWriteAllDataFalse" }) do
  resetClipboard()
  frontmostName = "Cursor"
  failureMode = mode
  local priorRestoreAlerts = #alerts
  priorNotifications = #hudNotifications
  assertEqual(action.run(), false, "Cursor " .. mode .. " is reported")
  assertEqual(pasteboard.contents, "before", "failed restoration preserves original clipboard")
  assertEqual(#hudNotifications, priorNotifications, "failed restoration has no HUD")
  assertEqual(#alerts, priorRestoreAlerts + 1, "failed restoration shows one alert")
  assertEqual(alerts[#alerts], "クリップボードを復元できませんでした。",
    "failed restoration alert message")
end

-- An external clipboard writer wins the race and is never overwritten or restored.
resetClipboard()
frontmostName = "Cursor"
cursorClipboardConflict = true
local conflictChangeCount = pasteboard.changeCount
priorNotifications = #hudNotifications
priorAlerts = #alerts
assertEqual(action.run(), false, "Cursor clipboard conflict is rejected")
assertEqual(pasteboard.contents, "/Users/external/important.txt",
  "Cursor clipboard conflict preserves current value")
assert(pasteboard.changeCount > conflictChangeCount, "Cursor clipboard conflict changes the current count")
assertEqual(#pasteboardWrites, 0, "Cursor clipboard conflict does not write or restore")
assertEqual(#hudNotifications, priorNotifications, "Cursor clipboard conflict has no HUD")
assertEqual(#alerts, priorAlerts + 1, "Cursor clipboard conflict shows one alert")

-- Empty clipboard restoration uses clearContents and retains the no-menu contract.
resetClipboard()
frontmostName = "Cursor"
pasteboard.contents = nil
pasteboard.changeCount = 1
pasteboard.types = {}
pasteboard.data = {}
failureMode = "setContents"
priorNotifications = #hudNotifications
assertEqual(action.run(), false, "empty clipboard final write failure is reported")
assertEqual(pasteboard.contents, nil, "empty clipboard restoration clears contents")
assertEqual(clearContentsCalls, 1, "empty restoration uses clearContents")
assertEqual(#hudNotifications, priorNotifications, "empty restoration has no HUD")

for _, mode in ipairs({ "restoreClearContents", "restoreClearContentsFalse" }) do
  resetClipboard()
  frontmostName = "Cursor"
  pasteboard.contents = nil
  pasteboard.changeCount = 1
  pasteboard.types = {}
  pasteboard.data = {}
  failureMode = mode
  local priorEmptyRestoreAlerts = #alerts
  assertEqual(action.run(), false, "empty clipboard " .. mode .. " is reported")
  assertEqual(pasteboard.contents, nil, "failed empty restoration preserves empty clipboard")
  assertEqual(#alerts, priorEmptyRestoreAlerts + 1, "failed empty restoration shows one alert")
  assertEqual(alerts[#alerts], "クリップボードを復元できませんでした。",
    "failed empty restoration alert message")
end

print("file_name_copy_test: ok")
