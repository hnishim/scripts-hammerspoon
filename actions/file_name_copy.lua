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

local function frontmostName()
  if type(hs) ~= "table" or type(hs.application) ~= "table"
      or type(hs.application.frontmostApplication) ~= "function" then
    return nil
  end
  local appOK, app = pcall(hs.application.frontmostApplication)
  if not appOK or not app or type(app.name) ~= "function" then return nil end
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

local function copiedPathName(path)
  return basename(path)
end

local function runCursor()
  local snapshotOK, snapshot, beforeCount = clipboardSnapshot()
  if not snapshotOK then
    alert("クリップボードを安全に退避できないため、Cursorの処理を中止しました。")
    return false
  end
  if type(hs.eventtap) ~= "table" or type(hs.eventtap.keyStroke) ~= "function"
      or type(hs.timer) ~= "table" or type(hs.timer.doAfter) ~= "function" then
    alert("Cursorの選択項目を取得できませんでした。")
    return false
  end

  local generation = operationGeneration
  local firstOK, firstResult = pcall(hs.eventtap.keyStroke, { "cmd" }, "r")
  local secondOK, secondResult = pcall(hs.eventtap.keyStroke, {}, "p")
  if not firstOK or firstResult == false or not secondOK or secondResult == false then
    alert("Cursorの選択項目を取得できませんでした。")
    return false
  end

  local countOK, afterKeyCount = readChangeCount()
  local expectedCount = countOK and afterKeyCount > beforeCount and afterKeyCount or nil
  local timerOK, timer = pcall(hs.timer.doAfter, 0.2, function()
    if operationGeneration ~= generation then return end
    pendingTimer = nil
    local currentCountOK, currentCount = readChangeCount()
    local currentContentsOK, currentContents = readContents()
    if not currentCountOK or not currentContentsOK then
      alert("Cursorの選択項目を取得できませんでした。")
      return
    end
    if expectedCount and currentCount ~= expectedCount then
      alert("クリップボードの競合を検出したため、復元せず終了しました。")
      return
    end
    if not expectedCount and currentCount <= beforeCount then
      alert("Cursorの選択項目を取得できませんでした。")
      return
    end
    local name = copiedPathName(currentContents)
    if not name then
      restoreClipboard(snapshot, currentContents, currentCount)
      alert("Cursorから有効なファイルパスを取得できませんでした。")
      return
    end
    if not clipboardMatches(currentContents, currentCount) then
      alert("クリップボードの競合を検出したため、復元せず終了しました。")
      return
    end
    if writeContents(name) then return end
    if not restoreClipboard(snapshot, currentContents, currentCount) then
      alert("クリップボードを復元できませんでした。")
      return
    end
    alert("ファイル名をクリップボードへコピーできませんでした。")
  end)
  if not timerOK or not timer then
    alert("Cursorの選択項目を取得できませんでした。")
    return false
  end
  pendingTimer = timer
  return true
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
