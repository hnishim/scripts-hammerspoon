local aiCommands = require("actions.ai_commands")
local appLauncher = require("actions.app_launcher")
local windowManagement = require("actions.window_management")
local utilityCommand = require("actions.utility_command")

local M = {}
local handles = {}

local bindings = {
  { modifiers = { "cmd", "alt", "shift" }, key = "B", callback = function() return aiCommands.run("B") end },
  { modifiers = { "cmd", "alt", "shift" }, key = "R", callback = function() return aiCommands.run("R") end },
  { modifiers = { "cmd", "alt", "shift" }, key = "T", callback = function() return aiCommands.run("T") end },
}

local appBindings = {
  { "a", "Microsoft Teams" }, { "b", "Arc" }, { "c", "Ferdium" },
  { "d", "Cogito" }, { "e", "Cursor" }, { "f", "Finder" },
  { "i", "ChatGPT" }, { "j", "Dictionaries" }, { "k", "Linear" },
  { "m", "Meru" }, { "n", "Notion" }, { "p", "Microsoft PowerPoint" },
  { "r", "Reminders" }, { "s", "Slack" }, { "t", "Warp" },
  { "w", "1Password" }, { "x", "Microsoft Excel" }, { "z", "zoom.us" },
}
local function appCallback(app)
  return function() return appLauncher.launch(app) end
end
for _, appBinding in ipairs(appBindings) do
  local key, app = appBinding[1], appBinding[2]
  bindings[#bindings + 1] = {
    modifiers = { "cmd", "ctrl", "alt", "shift" }, key = key,
    callback = appCallback(app),
  }
end
for _, key in ipairs({ "t", "c", "g", "r", "n", "f" }) do
  bindings[#bindings + 1] = {
    modifiers = { "cmd", "ctrl" }, key = key,
    callback = function() return windowManagement.run(key) end,
  }
end
for _, key in ipairs({ "f", "c" }) do
  bindings[#bindings + 1] = {
    modifiers = { "cmd", "alt", "shift" }, key = key,
    callback = function() return utilityCommand.run(key) end,
  }
end

local function deleteHandles(values)
  for _, handle in ipairs(values) do
    if handle and handle.delete then pcall(handle.delete, handle) end
  end
end

local function stopAction(action)
  if action and action.stop then pcall(action.stop) end
end

function M.start()
  stopAction(aiCommands)
  stopAction(windowManagement)
  stopAction(utilityCommand)
  deleteHandles(handles)
  handles = {}
  local newHandles = {}
  for _, binding in ipairs(bindings) do
    local ok, handle = pcall(hs.hotkey.bind, binding.modifiers, binding.key, binding.callback)
    if not ok or not handle then
      deleteHandles(newHandles)
      return false
    end
    newHandles[#newHandles + 1] = handle
  end
  handles = newHandles
  return true
end

return M
