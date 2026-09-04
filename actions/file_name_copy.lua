local M = {}
local hud = require("components.hud")

local operationGeneration = 0
local pendingTimer

local function alert(message)
  if type(hs) == "table" and type(hs.alert) == "table" and type(hs.alert.show) == "function" then
    pcall(hs.alert.show, message, 2)
  end
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
    alert("Finderの選択項目を取得できませんでした。")
    return false
  end
  if not writeContents(contents) then
    alert("ファイル名をクリップボードへコピーできませんでした。")
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

local function selectedExplorerPath(element)
  for _, attribute in ipairs({ "AXSelectedRows", "AXSelectedChildren" }) do
    local selected = axElements(axAttribute(element, attribute))
    if #selected > 0 then
      if #selected ~= 1 then return nil end
      return axPathInSubtree(selected[1], 0)
    end
  end
  return nil
end

local function isExplorerContainer(element)
  if axAttribute(element, "AXRole") ~= "AXOutline" then return false end
  for _, attribute in ipairs({ "AXTitle", "AXDescription", "AXIdentifier" }) do
    local value = axAttribute(element, attribute)
    if type(value) == "string" and value:lower():find("explorer", 1, true) then
      return true
    end
  end
  return false
end

local function isExplorerFocus(element)
  local current = element
  for _ = 0, 40 do
    if isExplorerContainer(current) then return true end
    current = axAttribute(current, "AXParent")
    if not current then return false end
  end
  return false
end

local function cursorCopyCommand(app)
  if type(hs) ~= "table" or type(hs.axuielement) ~= "table"
      or type(hs.axuielement.systemWideElement) ~= "function"
      or not app then
    return nil
  end

  local systemOK, systemWide = pcall(hs.axuielement.systemWideElement)
  if not systemOK or not systemWide or type(systemWide.attributeValue) ~= "function" then
    return nil
  end
  local focusedOK, focused = pcall(systemWide.attributeValue, systemWide, "AXFocusedUIElement")
  if not focusedOK or not focused or type(focused.attributeValue) ~= "function" then
    return nil
  end
  local roleOK, role = pcall(focused.attributeValue, focused, "AXRole")
  if not roleOK then return nil end

  if (role == "AXOutline" or role == "AXRow") and isExplorerFocus(focused) then
    local expectedPath
    if role == "AXOutline" then
      expectedPath = selectedExplorerPath(focused)
    else
      expectedPath = axPathInSubtree(focused, 0)
    end
    if not expectedPath then return false end
    return true, expectedPath
  end

  local appElement = axElementForApp(app)
  if not appElement then return nil end
  local window = cursorWindow(appElement)
  local expectedPath = urlPath(axAttribute(window, "AXDocument"))
  if not expectedPath then return false end
  return true, expectedPath
end

local function runCursorDirect(snapshot, beforeCount, expectedPath)
  local name = copiedPathName(expectedPath)
  if not name then
    alert("Cursorから有効なファイルパスを取得できませんでした。")
    return false
  end
  if not clipboardMatches(snapshot.contents, beforeCount) then
    alert("クリップボードの競合を検出したため、復元せず終了しました。")
    return false
  end
  if writeContents(name) then return true end
  if restoreClipboard(snapshot, snapshot.contents, beforeCount) then
    alert("ファイル名をクリップボードへコピーできませんでした。")
  else
    alert("クリップボードを復元できませんでした。")
  end
  return false
end

local function runCursor()
  local snapshotOK, snapshot, beforeCount = clipboardSnapshot()
  if not snapshotOK then
    alert("クリップボードを安全に退避できないため、Cursorの処理を中止しました。")
    return false
  end
  local app = frontmostApplication()
  if frontmostName(app) ~= "Cursor" then
    alert("Cursorの選択項目を取得できませんでした。")
    return false
  end

  local copyOK, expectedPath = cursorCopyCommand(app)
  if not copyOK then
    alert("Cursorの選択項目を取得できませんでした。")
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
