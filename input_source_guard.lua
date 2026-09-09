local M = {}

local activeWatcher
local targetBundleIDs = {
  ["com.apple.finder"] = true,
  ["com.linear"] = true,
}
local sourceID = "jp.monokakido.inputmethod.Kawasemi4.Roman"

local function handleApplicationEvent(_, eventType, app)
  if eventType ~= hs.application.watcher.activated or not app then return end

  local ok, bundleID = pcall(function() return app:bundleID() end)
  if not ok or not targetBundleIDs[bundleID] then return end

  pcall(hs.keycodes.currentSourceID, sourceID)
end

local function stopWatcher(watcher)
  if not watcher or type(watcher.stop) ~= "function" then return false end
  local ok, result = pcall(watcher.stop, watcher)
  return ok and result ~= false
end

function M.start()
  local previousWatcher = activeWatcher
  activeWatcher = nil
  stopWatcher(previousWatcher)

  local newOK, watcher = pcall(hs.application.watcher.new, handleApplicationEvent)
  if not newOK or not watcher or type(watcher.start) ~= "function" then return false end

  local startOK, result = pcall(watcher.start, watcher)
  if not startOK or result == false then
    pcall(watcher.stop, watcher)
    return false
  end

  activeWatcher = watcher
  return true
end

return M
