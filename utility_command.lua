local M = {}

local home = os.getenv("HOME") or ""
local scriptsRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts"
local raycastRoot = scriptsRoot .. "/raycast"
local mimiBin = os.getenv("MIMI_BIN") or "/opt/homebrew/bin/mimi"

local mimiModifiers = { "cmd", "ctrl" }
local scriptModifiers = { "cmd", "alt", "shift" }
local runningTasks = {}
local taskSequence = 0
local mimiState = { direction = nil, cycle = 0 }

local mimiCommands = {
  t = {
    direction = 1,
    layouts = {
      { "100", "50", "bl" },
      { "100", "33.333333", "bl" },
      { "100", "66.666667", "bl" },
    },
  },
  c = {
    direction = 2,
    layouts = {
      { "50", "100", "cc" },
      { "33.333333", "100", "cc" },
      { "66.666667", "100", "cc" },
    },
  },
  g = {
    direction = 3,
    layouts = {
      { "50", "100", "tl" },
      { "33.333333", "100", "tl" },
      { "66.666667", "100", "tl" },
    },
  },
  r = {
    direction = 4,
    layouts = {
      { "50", "100", "tr" },
      { "33.333333", "100", "tr" },
      { "66.666667", "100", "tr" },
    },
  },
  n = {
    direction = 5,
    layouts = {
      { "100", "50", "tl" },
      { "100", "33.333333", "tl" },
      { "100", "66.666667", "tl" },
    },
  },
}

local function showError()
  if hs.alert and hs.alert.show then pcall(hs.alert.show, "コマンドを実行できませんでした。", 2) end
end

local function releaseTask(record)
  if record.finished then return end
  record.finished = true
  if runningTasks[record.id] == record then runningTasks[record.id] = nil end
end

local function runTask(path, arguments)
  taskSequence = taskSequence + 1
  local record = { id = taskSequence, task = nil, finished = false }
  local function callback(exitCode, _stdout, _stderr)
    local failed = exitCode ~= 0
    releaseTask(record)
    if failed then showError() end
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

local function nextMimiLayout(command)
  if mimiState.direction ~= command.direction then
    mimiState.direction = command.direction
    mimiState.cycle = 1
  elseif mimiState.cycle == 1 then
    mimiState.cycle = 2
  elseif mimiState.cycle == 2 then
    mimiState.cycle = 0
  else
    mimiState.cycle = 1
  end
  return command.layouts[mimiState.cycle == 0 and 3 or mimiState.cycle]
end

local function runMimi(command)
  local layout = nextMimiLayout(command)
  runTask(mimiBin, {
    "action", "resize_window",
    "--width-percent", layout[1],
    "--height-percent", layout[2],
    "--anchor", layout[3],
  })
end

local function maximize()
  mimiState.direction = nil
  mimiState.cycle = 0
  runTask(mimiBin, {
    "action", "resize_window",
    "--width-percent", "100",
    "--height-percent", "100",
    "--anchor", "tl",
  })
end

local function runFinder()
  runTask("/usr/bin/osascript", { raycastRoot .. "/two-panes-finder.applescript" })
end

local function runTitleCase()
  runTask("/bin/bash", { raycastRoot .. "/title-case-chicago.sh" })
end

function M.start()
  for key, command in pairs(mimiCommands) do
    hs.hotkey.bind(mimiModifiers, key, function() runMimi(command) end)
  end
  hs.hotkey.bind(mimiModifiers, "f", maximize)
  hs.hotkey.bind(scriptModifiers, "f", runFinder)
  hs.hotkey.bind(scriptModifiers, "c", runTitleCase)
end

return M
