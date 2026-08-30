local M = {}

local runningTasks = {}
local taskSequence = 0

local function showError()
  if hs.alert and hs.alert.show then pcall(hs.alert.show, "コマンドを実行できませんでした。", 2) end
end

local function readableFile(path)
  if type(path) ~= "string" or path == "" then return false end
  local handle = io.open(path, "r")
  if not handle then return false end
  handle:close()
  return true
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

local function runTask(executablePath, scriptPath)
  if not readableFile(executablePath) or not readableFile(scriptPath) then return false end
  taskSequence = taskSequence + 1
  local record = { id = taskSequence, task = nil, finished = false }
  local function callback(exitCode, _stdout, _stderr)
    if record.finished then return end
    releaseTask(record)
    if exitCode ~= 0 then showError() end
  end
  local createdOK, task = pcall(hs.task.new, executablePath, callback, { scriptPath })
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

function M.run(executablePath, scriptPath)
  return runTask(executablePath, scriptPath)
end

return M
