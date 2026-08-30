local aiCommands = require("actions.ai_commands")
local appLauncher = require("actions.app_launcher")
local windowManagement = require("actions.window_management")
local utilityCommand = require("actions.utility_command")
local urlCommands = require("actions.url_commands")

local M = {}
local handles = {}
local home = os.getenv("HOME") or ""
local promptDir = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/prompts/ai-commands/"
local raycastRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast/"

-- AIコマンド
local bindings = {
  { modifiers = { "cmd", "alt", "shift" }, key = "B", callback = function()
    return aiCommands.run(promptDir .. "bio-ai_expert.md", "gemini-flash-lite-latest", "display")
  end },
  { modifiers = { "cmd", "alt", "shift" }, key = "R", callback = function()
    return aiCommands.run(promptDir .. "review-text_compact.md", "gemini-flash-lite-latest", "replace")
  end },
  { modifiers = { "cmd", "alt", "shift" }, key = "T", callback = function()
    return aiCommands.run(promptDir .. "translate.md", "gemini-flash-lite-latest", "replace")
  end },
}

-- アプリランチャー
local appBindings = {
  { "a", "Microsoft Teams" }, { "b", "Arc" }, { "c", "Ferdium" },
  { "d", "Cogito" }, { "e", "Cursor" }, { "f", "Finder" },
  { "i", "ChatGPT" }, { "j", "Dictionaries" }, { "k", "Linear" },
  { "m", "Meru" }, { "n", "Notion" }, { "p", "Microsoft PowerPoint" },
  { "r", "Reminders" }, { "s", "Slack" }, { "t", "Warp" },
  { "w", "1Password" }, { "x", "Microsoft Excel" }, { "z", "zoom.us" },
}
for _, appBinding in ipairs(appBindings) do
  local key, app = appBinding[1], appBinding[2]
  bindings[#bindings + 1] = {
    modifiers = { "cmd", "ctrl", "alt", "shift" }, key = key,
    callback = function() return appLauncher.run(app) end,
  }
end

-- ウィンドウ
for _, binding in ipairs({
  { "t", "bottom" }, { "c", "center" }, { "g", "left" },
  { "r", "right" }, { "n", "top" }, { "f", "full" },
}) do
  bindings[#bindings + 1] = {
    modifiers = { "cmd", "ctrl" }, key = binding[1],
    callback = function() return windowManagement.run(binding[2]) end,
  }
end

-- URL検索
for _, binding in ipairs({
  { "G", "google" }, { "J", "dictionary" },
}) do
  bindings[#bindings + 1] = {
    modifiers = { "cmd", "alt", "shift" }, key = binding[1],
    callback = function() return urlCommands.run(binding[2]) end,
  }
end

bindings[#bindings + 1] = {
  modifiers = { "ctrl", "cmd" }, key = "P",
  callback = function() return windowManagement.run("previous-display") end,
}

-- スクリプト起動
for _, binding in ipairs({
  { "f", "/usr/bin/osascript", raycastRoot .. "two-panes-finder.applescript" },
  { "c", "/bin/bash", raycastRoot .. "title-case-chicago.sh" },
}) do
  bindings[#bindings + 1] = {
    modifiers = { "cmd", "alt", "shift" }, key = binding[1],
    callback = function() return utilityCommand.run(binding[2], binding[3]) end,
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
