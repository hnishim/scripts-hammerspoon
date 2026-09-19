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
      -- Keep success and failure HUD observations separate for existing lifecycle checks.
      if message == "Copied" then
        hudNotifications[#hudNotifications + 1] = { message = message, seconds = seconds }
      else
        alerts[#alerts + 1] = message
      end
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
  assertEqual(alerts[#alerts], "Could not restore the clipboard.",
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
  assertEqual(alerts[#alerts], "Could not restore the clipboard.",
    "failed empty restoration alert message")
end


-- HIR-279: selection-acquisition diagnostics are observable without changing clipboard behavior.
-- These tests exercise the real action via a mocked macOS Accessibility boundary.
local diagnosticLines = {}
hs.logger = {
  new = function()
    local function record(_, line)
      diagnosticLines[#diagnosticLines + 1] = line
    end
    return { w = record, e = record, i = record, warning = record, error = record }
  end,
}

local function assertDiagnostic(stage, kind, description, extras)
  assertEqual(#diagnosticLines, 1, description .. " emits exactly one diagnostic")
  local line = diagnosticLines[1]
  assertEqual(type(line), "string", description .. " emits a string")
  assert(not line:find("[\r\n]"), description .. " emits one line")
  for _, field in ipairs({
    "issue=HIR-279", "stage=" .. stage, "kind=" .. kind, "timestamp=",
  }) do
    assert(line:find(field, 1, true), description .. " missing " .. field .. ": " .. line)
  end
  for _, field in ipairs(extras or {}) do
    assert(line:find(field, 1, true), description .. " missing " .. field .. ": " .. line)
  end
  for _, secret in ipairs({
    "SECRET-CLIPBOARD-VALUE", "SECRET-PRIVATE-PATH", "/Users/test/",
    "file://", "SECRET-AX-TITLE",
  }) do
    assert(not line:find(secret, 1, true), description .. " leaked " .. secret)
  end
  assert(#line <= 2048, description .. " diagnostic is bounded")
end

local originalSystemWide = hs.axuielement.systemWideElement
local originalApplicationElement = hs.axuielement.applicationElement
local originalFrontmostApplication = hs.application.frontmostApplication
local function diagnosticCase(description, options)
  resetClipboard()
  frontmostName = "Cursor"
  diagnosticLines = {}
  local initialClipboard = pasteboard.changeCount
  pasteboard.contents = "SECRET-CLIPBOARD-VALUE"
  pasteboard.data["public.utf8-plain-text"] = pasteboard.contents
  local originalContents = pasteboard.contents
  cursorActiveFile = "/Users/test/SECRET-PRIVATE-PATH/active.lua"
  cursorExplorerFile = "/Users/test/SECRET-PRIVATE-PATH/selected.lua"
  cursorExplorerFolder = "/Users/test/SECRET-PRIVATE-PATH/folder"

  failureMode = options.failureMode
  cursorFocus = options.focus or "editor"
  hs.application.frontmostApplication = originalFrontmostApplication
  hs.axuielement.systemWideElement = originalSystemWide
  hs.axuielement.applicationElement = originalApplicationElement

  if options.frontmostChanges then
    local queries = 0
    hs.application.frontmostApplication = function()
      queries = queries + 1
      if queries == 1 then return originalFrontmostApplication() end
      return { name = function() return "Safari" end, pid = function() return 234 end }
    end
  end
  if options.missingAppElement then
    hs.axuielement.applicationElement = function() return nil end
  end
  if options.mutateAX or options.focusQueryException then
    hs.axuielement.systemWideElement = function()
      local system = originalSystemWide()
      if options.focusQueryException then
        system.attributeValue = function() error("SECRET-AX-TITLE") end
      elseif system and options.mutateAX then
        options.mutateAX(cursorAXModel)
      end
      return system
    end
  end
  local alertCount, successCount = #alerts, #hudNotifications
  local ok = action.run()
  hs.application.frontmostApplication = originalFrontmostApplication
  hs.axuielement.systemWideElement = originalSystemWide
  hs.axuielement.applicationElement = originalApplicationElement
  assertEqual(ok, false, description .. " does not copy")
  assertEqual(#alerts, alertCount + 1, description .. " retains its one selection error alert")
  assertEqual(alerts[#alerts], "Could not get the selected item from Cursor.",
    description .. " does not change user-facing behavior")
  assertEqual(#hudNotifications, successCount, description .. " has no success HUD")
  assertEqual(#pasteboardWrites, 0, description .. " never writes clipboard")
  assertEqual(pasteboard.contents, originalContents, description .. " preserves clipboard value")
  assertEqual(pasteboard.changeCount, initialClipboard, description .. " preserves clipboard count")
  assertEqual(timerCalls, 0, description .. " does not schedule a retry")
  assertEqual(#performedActions, 0, description .. " does not perform new AX actions")
  assertDiagnostic(options.stage, options.kind, description, options.extras)
end

diagnosticCase("frontmost changed after dispatch", {
  frontmostChanges = true, stage = "frontmost-app", kind = "mismatch",
})
diagnosticCase("system-wide API returned nil", {
  failureMode = "cursorReturn", stage = "system-wide-element", kind = "nil",
})
diagnosticCase("system-wide API raised", {
  failureMode = "cursorError", stage = "system-wide-element", kind = "exception",
})
diagnosticCase("focused element was nil", {
  focus = "missing", stage = "focus-query", kind = "nil",
})
diagnosticCase("focused element query raised", {
  focusQueryException = true, stage = "focus-query", kind = "exception",
})
diagnosticCase("focused role query raised", {
  mutateAX = function(model)
    model.focused.attributeValue = function(_, attribute)
      if attribute == "AXRole" then error("SECRET-AX-TITLE") end
      return nil
    end
  end,
  stage = "focused-role", kind = "exception",
})
diagnosticCase("Explorer focused row has no valid path", {
  focus = "explorer-file",
  mutateAX = function(model)
    model.focused.attributeValue = function(_, attribute)
      if attribute == "AXParent" then return makeAXElement({ AXRole = "AXOutline", AXTitle = "Files Explorer" }) end
      if attribute == "AXRole" then return "AXRow" end
      if attribute == "AXTitle" then return "SECRET-AX-TITLE" end
      return nil
    end
  end,
  stage = "explorer-path", kind = "nil", extras = { "explorer=true" },
})
diagnosticCase("Explorer multiple selection cannot yield one path", {
  focus = "explorer-outline",
  mutateAX = function(model)
    local focused = model.focused
    local originalAttribute = focused.attributeValue
    focused.attributeValue = function(self, attribute)
      if attribute == "AXSelectedRows" then
        return { makeAXElement({ AXRole = "AXRow" }), makeAXElement({ AXRole = "AXRow" }) }
      end
      return originalAttribute(self, attribute)
    end
  end,
  stage = "explorer-path", kind = "invalid", extras = { "selection_count=2" },
})
diagnosticCase("Cursor application AX element missing", {
  missingAppElement = true, stage = "app-element", kind = "nil",
})
diagnosticCase("focused and main windows both missing", {
  mutateAX = function(model)
    model.appElement.attributeValue = function(_, attribute)
      if attribute == "AXChildren" then return {} end
      return nil
    end
  end,
  stage = "window", kind = "nil",
})
diagnosticCase("window document is nil", {
  mutateAX = function(model)
    local window = model.appElement:attributeValue("AXFocusedWindow")
    local originalAttribute = window.attributeValue
    window.attributeValue = function(self, attribute)
      if attribute == "AXDocument" then return nil end
      return originalAttribute(self, attribute)
    end
  end,
  stage = "active-document", kind = "nil",
  extras = { "window_source=focused", "explorer=false", "document_state=nil" },
})
diagnosticCase("window document is not a file URL", {
  mutateAX = function(model)
    local window = model.appElement:attributeValue("AXFocusedWindow")
    local originalAttribute = window.attributeValue
    window.attributeValue = function(self, attribute)
      if attribute == "AXDocument" then return "https://example.invalid/SECRET-PRIVATE-PATH" end
      return originalAttribute(self, attribute)
    end
  end,
  stage = "active-document", kind = "invalid",
  extras = { "document_state=non-file" },
})
diagnosticCase("window document query raised", {
  mutateAX = function(model)
    local window = model.appElement:attributeValue("AXFocusedWindow")
    local originalAttribute = window.attributeValue
    window.attributeValue = function(self, attribute)
      if attribute == "AXDocument" then error("SECRET-AX-TITLE") end
      return originalAttribute(self, attribute)
    end
  end,
  stage = "active-document", kind = "exception",
})
diagnosticCase("non-Explorer outline is classified as fallback", {
  focus = "non-explorer-outline",
  mutateAX = function(model)
    local window = model.appElement:attributeValue("AXFocusedWindow")
    local originalAttribute = window.attributeValue
    window.attributeValue = function(self, attribute)
      if attribute == "AXDocument" then return nil end
      return originalAttribute(self, attribute)
    end
  end,
  stage = "active-document", kind = "nil", extras = { "explorer=false" },
})

-- A missing or unsuitable role does not silently become a valid Explorer classification.
-- The subsequent missing document remains the terminal failure, with the role state retained.
for _, roleCase in ipairs({
  { label = "nil", role = nil },
  { label = "invalid", role = 12 },
}) do
  diagnosticCase("focused role " .. roleCase.label .. " then missing document", {
    mutateAX = function(model)
      local focusAttribute = model.focused.attributeValue
      model.focused.attributeValue = function(self, attribute)
        if attribute == "AXRole" then return roleCase.role end
        return focusAttribute(self, attribute)
      end
      local window = model.appElement:attributeValue("AXFocusedWindow")
      local windowAttribute = window.attributeValue
      window.attributeValue = function(self, attribute)
        if attribute == "AXDocument" then return nil end
        return windowAttribute(self, attribute)
      end
    end,
    stage = "active-document", kind = "nil",
    extras = { "focused_role_state=" .. roleCase.label, "explorer=false", "document_state=nil" },
  })
end

-- An AXOutline ancestor with absent identifying attributes must be distinct from a true non-Explorer.
diagnosticCase("Explorer outline lacks identifying attributes and fallback document", {
  focus = "explorer-file",
  mutateAX = function(model)
    local unclassifiedOutline = makeAXElement({ AXRole = "AXOutline" })
    local focusedAttribute = model.focused.attributeValue
    model.focused.attributeValue = function(self, attribute)
      if attribute == "AXParent" then return unclassifiedOutline end
      return focusedAttribute(self, attribute)
    end
    local window = model.appElement:attributeValue("AXFocusedWindow")
    local windowAttribute = window.attributeValue
    window.attributeValue = function(self, attribute)
      if attribute == "AXDocument" then return nil end
      return windowAttribute(self, attribute)
    end
  end,
  stage = "active-document", kind = "nil",
  extras = {
    "focused_role=AXRow", "explorer=false", "ancestor_role=AXOutline",
    "ancestor_title_present=false", "ancestor_description_present=false",
    "ancestor_identifier_present=false", "ancestor_explorer_match=false",
    "document_state=nil",
  },
})

-- FocusedWindow missing while MainWindow exists must preserve the selected fallback source.
diagnosticCase("main window fallback still has no document", {
  mutateAX = function(model)
    local appAttribute = model.appElement.attributeValue
    model.appElement.attributeValue = function(self, attribute)
      if attribute == "AXFocusedWindow" then return nil end
      return appAttribute(self, attribute)
    end
    local window = model.appElement:attributeValue("AXMainWindow")
    local windowAttribute = window.attributeValue
    window.attributeValue = function(self, attribute)
      if attribute == "AXDocument" then return nil end
      return windowAttribute(self, attribute)
    end
  end,
  stage = "active-document", kind = "nil",
  extras = {
    "focused_window=false", "main_window=true", "window_source=main",
    "document_state=nil",
  },
})

-- An absent/failing logger must never interfere with error presentation or clipboard safety.
resetClipboard()
frontmostName = "Cursor"
cursorFocus = "missing"
diagnosticLines = {}
local savedLogger = hs.logger
hs.logger = { new = function() error("logger unavailable") end }
local priorDiagnosticAlerts = #alerts
assertEqual(action.run(), false, "diagnostic logger failure is nonfatal")
assertEqual(#alerts, priorDiagnosticAlerts + 1, "diagnostic logger failure preserves the alert")
assertEqual(#pasteboardWrites, 0, "diagnostic logger failure does not mutate the clipboard")
hs.logger = savedLogger

-- Successful Explorer/Editor copies and clipboard-specific failures do not emit selection diagnostics.
for _, focus in ipairs({ "editor", "explorer-file", "explorer-folder" }) do
  resetClipboard()
  frontmostName = "Cursor"
  cursorFocus = focus
  diagnosticLines = {}
  assertEqual(action.run(), true, "normal " .. focus .. " copy succeeds with logger enabled")
  assertEqual(#diagnosticLines, 0, "normal " .. focus .. " copy has no diagnostic")
end
resetClipboard()
frontmostName = "Cursor"
failureMode = "allContentTypes"
diagnosticLines = {}
assertEqual(action.run(), false, "clipboard snapshot error still aborts early")
assertEqual(#diagnosticLines, 0, "clipboard error does not masquerade as AX selection failure")

print("file_name_copy_test: ok")
