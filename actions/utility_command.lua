local M = {}

local home = os.getenv("HOME") or ""
local raycastRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast"
local runningTasks = {}
local taskSequence = 0

local function showError()
  if hs.alert and hs.alert.show then pcall(hs.alert.show, "コマンドを実行できませんでした。", 2) end
end

local function releaseTask(record)
  if record.finished then return end
  record.finished = true
  if runningTasks[record.id] == record then runningTasks[record.id] = nil end
end

local function clearTasks()
  for _, record in pairs(runningTasks) do
    releaseTask(record)
    if record.task and record.task.terminate then pcall(record.task.terminate, record.task) end
  end
end

local function runTask(path, arguments)
  taskSequence = taskSequence + 1
  local record = { id = taskSequence, task = nil, finished = false }
  local function callback(exitCode, _stdout, _stderr)
    if record.finished then return end
    releaseTask(record)
    if exitCode ~= 0 then showError() end
  end
  local createdOK, task = pcall(hs.task.new, path, callback, arguments)
  if not createdOK or not task then showError(); return false end
  record.task = task
  runningTasks[record.id] = record
  local startedOK, started = pcall(task.start, task)
  if not startedOK or started == false then
    releaseTask(record)
    showError()
    return false
  end
  if record.finished then runningTasks[record.id] = nil end
  return true
end

function M.stop()
  clearTasks()
end

function M.run(key)
  if key == "f" then return runTask("/usr/bin/osascript", { raycastRoot .. "/two-panes-finder.applescript" }) end
  if key == "c" then return runTask("/bin/bash", { raycastRoot .. "/title-case-chicago.sh" }) end
  return false
end

return M
