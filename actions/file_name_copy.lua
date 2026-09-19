local M = {}
local hud = require("components.hud")

local operationGeneration = 0
local pendingTimer

local function alert(message)
  pcall(hud.showTransient, message, 2)
end

local function stopTimer(timer)
  if timer and type(timer.stop) == "function" then pcall(timer.stop, timer) end
end

function M.stop()
  operationGeneration = operationGeneration + 1
  stopTimer(pendingTimer)
  pendingTimer = nil
end

local function frontmostApplication()
  if type(hs) ~= "table" or type(hs.application) ~= "table"
      or type(hs.application.frontmostApplication) ~= "function" then
    return nil
  end
  local appOK, app = pcall(hs.application.frontmostApplication)
  return appOK and app or nil
end

local function frontmostName(app)
  app = app or frontmostApplication()
  if not app or type(app.name) ~= "function" then return nil end
  local nameOK, name = pcall(app.name, app)
  return nameOK and name or nil
end

local function basename(path)
  if type(path) ~= "string" or not path:match("^/") or path:find("[\r\n]") then return nil end
  local trimmed = path:gsub("/+$", "")
  if trimmed == "" then return nil end
  return trimmed:match("([^/]+)$")
end

local function finderFileNames()
  if type(hs) ~= "table" or type(hs.osascript) ~= "table"
      or type(hs.osascript.applescript) ~= "function" then
    return nil
  end
  local script = [[
tell application "Finder"
  set selectedItems to selection
  set selectedPaths to {}
  repeat with selectedItem in selectedItems
    set end of selectedPaths to POSIX path of (selectedItem as alias)
  end repeat
  return selectedPaths
end tell
]]
  local callOK, scriptOK, paths = pcall(hs.osascript.applescript, script)
  if not callOK or scriptOK ~= true or type(paths) ~= "table" or #paths == 0 then return nil end
  local names = {}
  for index, path in ipairs(paths) do
    local name = basename(path)
    if not name then return nil end
    names[index] = name
  end
  return table.concat(names, "\n")
end

local function writeContents(value)
  if type(hs) ~= "table" or type(hs.pasteboard) ~= "table"
      or type(hs.pasteboard.setContents) ~= "function" then return false end
  local ok, result = pcall(hs.pasteboard.setContents, value)
  if ok and result ~= false and type(hud) == "table" and type(hud.showTransient) == "function" then
    pcall(hud.showTransient, "Copied", 2)
  end
  return ok and result ~= false
end

local function readChangeCount()
  if type(hs) ~= "table" or type(hs.pasteboard) ~= "table"
      or type(hs.pasteboard.changeCount) ~= "function" then return false end
  local ok, value = pcall(hs.pasteboard.changeCount)
  return ok and type(value) == "number", value
end

local function readContents()
  if type(hs) ~= "table" or type(hs.pasteboard) ~= "table"
      or type(hs.pasteboard.getContents) ~= "function" then return false end
  local ok, value = pcall(hs.pasteboard.getContents)
  return ok, value
end

local function copyData(data)
  local copy = {}
  for uti, value in pairs(data) do copy[uti] = value end
  return copy
end

local function clipboardSnapshot()
  if type(hs) ~= "table" or type(hs.pasteboard) ~= "table"
      or type(hs.pasteboard.allContentTypes) ~= "function"
      or type(hs.pasteboard.readAllData) ~= "function" then
    return false
  end
  local beforeOK, beforeCount = readChangeCount()
  if not beforeOK then return false end
  local typesOK, types = pcall(hs.pasteboard.allContentTypes)
  if not typesOK or type(types) ~= "table" then return false end
  local contentsOK, contents = readContents()
  if not contentsOK then return false end
  local afterOK, afterCount = readChangeCount()
  if not afterOK or beforeCount ~= afterCount then return false end
  if #types == 0 then
    return true, { empty = true, contents = contents }, afterCount
  end
  if #types ~= 1 or type(types[1]) ~= "table" then return false end
  local dataOK, data = pcall(hs.pasteboard.readAllData)
  if not dataOK or type(data) ~= "table" then return false end
  for _, uti in ipairs(types[1]) do
    if type(uti) ~= "string" or data[uti] == nil then return false end
  end
  return true, { empty = false, contents = contents, data = copyData(data) }, afterCount
end

local function clipboardMatches(contents, changeCount)
  local countOK, currentCount = readChangeCount()
  if not countOK or currentCount ~= changeCount then return false end
  local contentsOK, currentContents = readContents()
  return contentsOK and currentContents == contents
end

local function restoreClipboard(snapshot, expectedContents, expectedCount)
  if not snapshot or not clipboardMatches(expectedContents, expectedCount) then return false end
  if snapshot.empty then
    if type(hs.pasteboard.clearContents) ~= "function" then return false end
    local ok, result = pcall(hs.pasteboard.clearContents)
    return ok and result ~= false
  end
  if type(hs.pasteboard.writeAllData) ~= "function" then return false end
  local ok, result = pcall(hs.pasteboard.writeAllData, snapshot.data)
  return ok and result ~= false
end

local function runFinder()
  local contents = finderFileNames()
  if not contents then
    alert("Could not get selected Finder items.")
    return false
  end
  if not writeContents(contents) then
    alert("Could not copy the file name to the clipboard.")
    return false
  end
  return true
end

local urlPath

local function copiedPathName(path)
  return basename(urlPath(path) or path)
end

local function axAttribute(element, attribute)
  if not element or type(element.attributeValue) ~= "function" then return nil end
  local ok, value = pcall(element.attributeValue, element, attribute)
  return ok and value or nil
end

local function axChildren(element)
  local children = axAttribute(element, "AXChildren")
  return type(children) == "table" and children or {}
end

local function axElements(value)
  if type(value) == "table" then return value end
  if value then return { value } end
  return {}
end

local function axElementForApp(app)
  if type(hs) ~= "table" or type(hs.axuielement) ~= "table"
      or type(hs.axuielement.applicationElement) ~= "function"
      or not app or type(app.pid) ~= "function" then
    return nil
  end
  local pidOK, pid = pcall(app.pid, app)
  if not pidOK or type(pid) ~= "number" then return nil end
  local elementOK, element = pcall(hs.axuielement.applicationElement, pid)
  return elementOK and element or nil
end

local function cursorWindow(appElement)
  return axAttribute(appElement, "AXFocusedWindow")
    or axAttribute(appElement, "AXMainWindow")
    or axChildren(appElement)[1]
end

urlPath = function(url)
  if type(url) ~= "string" or url:find("[\r\n%z]") then return nil end
  local path = url
  if url:match("^file://") then
    local encodedPath = url:sub(8)
    if encodedPath:match("^/") then
      path = encodedPath
    elseif encodedPath:match("^localhost/") then
      path = encodedPath:gsub("^localhost", "")
    else
      return nil
    end
    path = path:gsub("[?#].*$", "")
  elseif not url:match("^/") then
    return nil
  end
  path = path:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  if not path:match("^/") or path:find("[\r\n%z]") then return nil end
  return path
end

local function axPathValue(value)
  local path = urlPath(value)
  if path then return path end
  if type(value) ~= "string" or value:find("[\r\n%z]") then return nil end
  local descriptionPath = value:match("^(.-)%s+•%s+") or value
  if descriptionPath:match("^~/") then
    local home = os.getenv("HOME")
    if type(home) ~= "string" or not home:match("^/") then return nil end
    descriptionPath = home .. descriptionPath:sub(2)
  end
  return urlPath(descriptionPath)
end

local function axPathInSubtree(element, depth)
  if not element or depth > 40 then return nil end
  for _, attribute in ipairs({ "AXURL", "AXDocument", "AXDescription" }) do
    local path = axPathValue(axAttribute(element, attribute))
    if path then return path end
  end
  for _, child in ipairs(axChildren(element)) do
    local path = axPathInSubtree(child, depth + 1)
    if path then return path end
  end
  return nil
end

local function selectedExplorerPath(element, diagnostic)
  for _, attribute in ipairs({ "AXSelectedRows", "AXSelectedChildren" }) do
    local selected = axElements(axAttribute(element, attribute))
    if #selected > 0 then
      diagnostic.selection_count = #selected
      if #selected ~= 1 then
        diagnostic.path_state = "invalid"
        return nil
      end
      return axPathInSubtree(selected[1], 0)
    end
  end
  diagnostic.selection_count = 0
  return nil
end

-- The diagnostic stores only classifications and attribute presence, never AX text or paths.
local function diagnosticRole(value)
  if type(value) ~= "string" then return "other" end
  for _, known in ipairs({ "AXOutline", "AXRow", "AXTextArea", "AXTextField",
      "AXGroup", "AXWindow" }) do
    if value == known then return known end
  end
  return "other"
end

local function diagnosticAppName(name)
  if type(name) ~= "string" then return "nil" end
  if #name > 48 or not name:match("^[%w%._ %-]+$") then return "other" end
  return name:gsub(" ", "_")
end

local function logCursorFailure(diagnostic)
  -- Never let an unavailable or throwing logger change the existing error path.
  pcall(function()
    if type(hs) ~= "table" or type(hs.logger) ~= "table"
        or type(hs.logger.new) ~= "function" then return end
    local logger = hs.logger.new("HIR-279", "warning")
    if not logger or type(logger.w) ~= "function" then return end
    local fields = {
      "issue=HIR-279", "operation=cursor-file-name-copy",
      "timestamp=" .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local keys = { "stage", "kind", "frontmost_app", "cursor", "focused_element",
      "focused_role_state", "focused_role", "explorer", "ancestor_role",
      "ancestor_title_present", "ancestor_description_present",
      "ancestor_identifier_present", "ancestor_explorer_match",
      "selection_count", "path_state", "app_element", "focused_window",
      "main_window", "window_source", "document_state" }
    for _, key in ipairs(keys) do
      local value = diagnostic[key]
      if value ~= nil then
        fields[#fields + 1] = key .. "=" .. tostring(value)
      end
    end
    logger:w(table.concat(fields, " "))
  end)
end

local function isExplorerContainer(element, diagnostic)
  local role = axAttribute(element, "AXRole")
  if role ~= "AXOutline" then return false end
  -- Retain the first outline classification even when its identifying attributes
  -- are absent: this distinguishes an unclassified Explorer from another pane.
  local attributes = { "AXTitle", "AXDescription", "AXIdentifier" }
  local matched = false
  local present = {}
  for _, attribute in ipairs(attributes) do
    local value = axAttribute(element, attribute)
    present[attribute] = value ~= nil
    if type(value) == "string" and value:lower():find("explorer", 1, true) then
      matched = true
    end
  end
  if diagnostic and (diagnostic.ancestor_role == nil or matched) then
    diagnostic.ancestor_role = "AXOutline"
    diagnostic.ancestor_title_present = tostring(present.AXTitle)
    diagnostic.ancestor_description_present = tostring(present.AXDescription)
    diagnostic.ancestor_identifier_present = tostring(present.AXIdentifier)
    diagnostic.ancestor_explorer_match = tostring(matched)
  end
  return matched
end

local function isExplorerFocus(element, diagnostic)
  local current = element
  for _ = 0, 40 do
    if isExplorerContainer(current, diagnostic) then return true end
    current = axAttribute(current, "AXParent")
    if not current then return false end
  end
  return false
end

local function cursorCopyCommand(app, diagnostic)
  if type(hs) ~= "table" or type(hs.axuielement) ~= "table"
      or type(hs.axuielement.systemWideElement) ~= "function" or not app then
    diagnostic.stage, diagnostic.kind = "system-wide-element", "unavailable"
    return nil
  end

  local systemOK, systemWide = pcall(hs.axuielement.systemWideElement)
  if not systemOK or not systemWide or type(systemWide.attributeValue) ~= "function" then
    diagnostic.stage = "system-wide-element"
    diagnostic.kind = not systemOK and "exception"
      or (not systemWide and "nil" or "invalid")
    return nil
  end
  local focusedOK, focused = pcall(systemWide.attributeValue, systemWide, "AXFocusedUIElement")
  diagnostic.focused_element = tostring(focusedOK and focused ~= nil)
  if not focusedOK or not focused or type(focused.attributeValue) ~= "function" then
    diagnostic.stage = "focus-query"
    diagnostic.kind = not focusedOK and "exception"
      or (not focused and "nil" or "invalid")
    return nil
  end
  local roleOK, role = pcall(focused.attributeValue, focused, "AXRole")
  diagnostic.focused_role_state = not roleOK and "exception"
    or (role == nil and "nil" or (type(role) ~= "string" and "invalid" or "ok"))
  diagnostic.focused_role = diagnosticRole(role)
  if not roleOK then
    diagnostic.stage, diagnostic.kind = "focused-role", "exception"
    return nil
  end

  diagnostic.explorer = "false"
  if (role == "AXOutline" or role == "AXRow") and isExplorerFocus(focused, diagnostic) then
    diagnostic.explorer = "true"
    local expectedPath
    if role == "AXOutline" then
      expectedPath = selectedExplorerPath(focused, diagnostic)
    else
      diagnostic.selection_count = 1
      expectedPath = axPathInSubtree(focused, 0)
    end
    if not expectedPath then
      diagnostic.stage = "explorer-path"
      diagnostic.kind = diagnostic.path_state == "invalid" and "invalid" or "nil"
      diagnostic.path_state = diagnostic.kind
      return false
    end
    diagnostic.path_state = "valid"
    return true, expectedPath
  end

  if type(hs.axuielement.applicationElement) ~= "function"
      or type(app.pid) ~= "function" then
    diagnostic.stage, diagnostic.kind = "app-element", "unavailable"
    return nil
  end
  local pidOK, pid = pcall(app.pid, app)
  if not pidOK or type(pid) ~= "number" then
    diagnostic.stage, diagnostic.kind = "app-element", pidOK and "invalid" or "exception"
    return nil
  end
  local appOK, appElement = pcall(hs.axuielement.applicationElement, pid)
  diagnostic.app_element = tostring(appOK and appElement ~= nil)
  if not appOK or not appElement then
    diagnostic.stage, diagnostic.kind = "app-element", appOK and "nil" or "exception"
    return nil
  end

  local window = axAttribute(appElement, "AXFocusedWindow")
  diagnostic.focused_window = tostring(window ~= nil)
  if window then
    diagnostic.window_source = "focused"
  else
    window = axAttribute(appElement, "AXMainWindow")
    diagnostic.main_window = tostring(window ~= nil)
    if window then
      diagnostic.window_source = "main"
    else
      window = axChildren(appElement)[1]
      diagnostic.window_source = window and "children" or "none"
    end
  end
  if not window then
    diagnostic.stage, diagnostic.kind = "window", "nil"
    return nil
  end
  local documentOK, document
  if type(window.attributeValue) == "function" then
    documentOK, document = pcall(window.attributeValue, window, "AXDocument")
  else
    documentOK, document = true, nil
  end
  if not documentOK then
    diagnostic.stage, diagnostic.kind = "active-document", "exception"
    diagnostic.document_state = "exception"
    return false
  end
  local expectedPath = urlPath(document)
  if not expectedPath then
    diagnostic.stage = "active-document"
    diagnostic.kind = document == nil and "nil" or "invalid"
    diagnostic.document_state = document == nil and "nil"
      or (type(document) ~= "string" and "non-string"
        or (document:match("^file://") and "invalid-file" or "non-file"))
    return false
  end
  diagnostic.document_state = type(document) == "string"
    and (document:match("^file://") and "file" or "absolute-path") or "invalid"
  return true, expectedPath
end

local function runCursorDirect(snapshot, beforeCount, expectedPath)
  local name = copiedPathName(expectedPath)
  if not name then
    alert("Could not get a valid file path from Cursor.")
    return false
  end
  if not clipboardMatches(snapshot.contents, beforeCount) then
    alert("Clipboard changed unexpectedly; stopped without restoring it.")
    return false
  end
  if writeContents(name) then return true end
  if restoreClipboard(snapshot, snapshot.contents, beforeCount) then
    alert("Could not copy the file name to the clipboard.")
  else
    alert("Could not restore the clipboard.")
  end
  return false
end

local function runCursor()
  local snapshotOK, snapshot, beforeCount = clipboardSnapshot()
  if not snapshotOK then
    alert("Could not safely preserve the clipboard; Cursor operation canceled.")
    return false
  end
  local app = frontmostApplication()
  local name = frontmostName(app)
  local diagnostic = { frontmost_app = diagnosticAppName(name),
    cursor = tostring(name == "Cursor") }
  if name ~= "Cursor" then
    diagnostic.stage, diagnostic.kind = "frontmost-app",
      name == nil and "nil" or "mismatch"
    logCursorFailure(diagnostic)
    alert("Could not get the selected item from Cursor.")
    return false
  end

  local copyOK, expectedPath = cursorCopyCommand(app, diagnostic)
  if not copyOK then
    logCursorFailure(diagnostic)
    alert("Could not get the selected item from Cursor.")
    return false
  end
  return runCursorDirect(snapshot, beforeCount, expectedPath)
end

function M.run()
  local appName = frontmostName()
  M.stop()
  if appName == "Finder" then
    return runFinder()
  end
  if appName == "Cursor" then return runCursor() end
  return false
end

return M
