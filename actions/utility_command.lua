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

local twoPaneFinderSuffix = "two-panes-finder.applescript"

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function taskArguments(scriptPath)
  if type(scriptPath) ~= "string" or scriptPath:sub(-#twoPaneFinderSuffix) ~= twoPaneFinderSuffix then
    return { scriptPath }
  end

  local windowOK, window = pcall(function() return hs.window.frontmostWindow() end)
  if not windowOK or not window then return { scriptPath } end

  local frameOK, frame = pcall(function() return window:frame() end)
  if not frameOK or type(frame) ~= "table" then return { scriptPath } end

  local values = { frame.x, frame.y, frame.w, frame.h }
  for index, value in ipairs(values) do
    if not isFiniteNumber(value) or ((index == 3 or index == 4) and value <= 0) then
      return { scriptPath }
    end
  end

  return {
    scriptPath,
    tostring(values[1]),
    tostring(values[2]),
    tostring(values[3]),
    tostring(values[4]),
  }
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
  local createdOK, task = pcall(hs.task.new, executablePath, callback, taskArguments(scriptPath))
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
