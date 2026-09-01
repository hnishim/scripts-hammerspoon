local aiCommands = require("actions.ai_commands")
local appLauncher = require("actions.app_launcher")
local windowManagement = require("actions.window_management")
local utilityCommand = require("actions.utility_command")
local urlCommands = require("actions.url_commands")
local fileNameCopy = require("actions.file_name_copy")

local M = {}
local handles = {}
local fileNameCopyEventTap
local lastError

local aiModes = { display = true, replace = true }
local windowCommands = {
  bottom = true,
  center = true,
  left = true,
  right = true,
  top = true,
  full = true,
  ["previous-display"] = true,
}
local urlCommandsAllowed = { google = true, dictionary = true }

local function deleteHandles(values)
  for _, handle in ipairs(values) do
    if handle and type(handle.delete) == "function" then pcall(handle.delete, handle) end
  end
end

local function stopAction(action)
  if action and type(action.stop) == "function" then pcall(action.stop) end
end

local function notifyError(message)
  if type(hs) ~= "table" or type(hs.alert) ~= "table" or type(hs.alert.show) ~= "function" then return end
  pcall(hs.alert.show, message, 2)
end

local function fail(message)
  lastError = message
  notifyError(message)
  return false
end

local function nonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

local function validateModifiers(modifiers, bindingIndex)
  local prefix = "binding " .. bindingIndex .. ".modifiers"
  if type(modifiers) ~= "table" or #modifiers == 0 then return false, prefix .. " must be a non-empty array" end
  local seen = {}
  for index = 1, #modifiers do
    local modifier = modifiers[index]
    if not nonEmptyString(modifier) then return false, prefix .. "[" .. index .. "] must be a non-empty string" end
    if seen[modifier] then return false, prefix .. " contains a duplicate modifier" end
    seen[modifier] = true
  end
  for key in pairs(modifiers) do
    if type(key) ~= "number" or key < 1 or key > #modifiers or key % 1 ~= 0 then
      return false, prefix .. " must be an array"
    end
  end
  return true
end

local function bindingSignature(modifiers, key)
  local normalized = {}
  for index, modifier in ipairs(modifiers) do normalized[index] = modifier end
  table.sort(normalized)
  return table.concat(normalized, "+") .. ":" .. key
end

local function validateAction(action, bindingIndex)
  local prefix = "binding " .. bindingIndex .. ".action"
  if type(action) ~= "table" then return false, prefix .. " must be a table" end
  if type(action.type) ~= "string" then return false, prefix .. ".type must be a string" end
  if action.type == "ai" then
    if not nonEmptyString(action.promptPath) then return false, prefix .. ".promptPath must be a non-empty string" end
    if not nonEmptyString(action.model) then return false, prefix .. ".model must be a non-empty string" end
    if aiModes[action.mode] ~= true then return false, prefix .. ".mode must be display or replace" end
    return true
  end
  if action.type == "app" then
    if not nonEmptyString(action.app) then return false, prefix .. ".app must be a non-empty string" end
    return true
  end
  if action.type == "window" then
    if windowCommands[action.command] ~= true then
      return false, prefix .. ".command is not an allowed window command"
    end
    return true
  end
  if action.type == "url" then
    if urlCommandsAllowed[action.command] ~= true then
      return false, prefix .. ".command is not an allowed URL command"
    end
    return true
  end
  if action.type == "utility" then
    if not nonEmptyString(action.executablePath) then
      return false, prefix .. ".executablePath must be a non-empty string"
    end
    if not nonEmptyString(action.scriptPath) then
      return false, prefix .. ".scriptPath must be a non-empty string"
    end
    return true
  end
  if action.type == "file_name_copy" then return true end
  return false, prefix .. ".type is unknown"
end

local function validateBindings(bindings)
  if type(bindings) ~= "table" then return false, "hotkeys_config must return a bindings array" end
  if #bindings == 0 then return false, "hotkeys_config bindings array must not be empty" end
  local seen = {}
  for key in pairs(bindings) do
    if type(key) ~= "number" or key < 1 or key > #bindings or key % 1 ~= 0 then
      return false, "hotkeys_config bindings must be an array"
    end
  end
  for index = 1, #bindings do
    local binding = bindings[index]
    if type(binding) ~= "table" then return false, "binding " .. index .. " must be a table" end
    local modifiersOK, modifiersError = validateModifiers(binding.modifiers, index)
    if not modifiersOK then return false, modifiersError end
    if not nonEmptyString(binding.key) then return false, "binding " .. index .. ".key must be a non-empty string" end
    local actionOK, actionError = validateAction(binding.action, index)
    if not actionOK then return false, actionError end
    local signature = bindingSignature(binding.modifiers, binding.key)
    if seen[signature] then return false, "binding " .. index .. " duplicates modifier/key " .. signature end
    seen[signature] = true
  end
  return true
end

local function loadBindings()
  local ok, bindingsOrError = pcall(require, "hotkeys_config")
  if not ok then return nil, "failed to load hotkeys_config: " .. tostring(bindingsOrError) end
  if type(bindingsOrError) ~= "table" then return nil, "hotkeys_config must return a bindings array" end
  local valid, validationError = validateBindings(bindingsOrError)
  if not valid then return nil, validationError end
  local bindings = bindingsOrError
  return bindings
end

local function dispatch(action)
  if action.type == "ai" then
    return aiCommands.run(action.promptPath, action.model, action.mode)
  end
  if action.type == "app" then return appLauncher.run(action.app) end
  if action.type == "window" then return windowManagement.run(action.command) end
  if action.type == "url" then return urlCommands.run(action.command) end
  return utilityCommand.run(action.executablePath, action.scriptPath)
end

local function callbackFor(action)
  return function() return dispatch(action) end
end

local function frontmostApplicationName()
  if type(hs) ~= "table" or type(hs.application) ~= "table"
      or type(hs.application.frontmostApplication) ~= "function" then
    return nil
  end
  local appOK, app = pcall(hs.application.frontmostApplication)
  if not appOK or not app or type(app.name) ~= "function" then return nil end
  local nameOK, name = pcall(app.name, app)
  if not nameOK then return nil end
  return name
end

local function exactFileNameCopyModifiers(flags)
  if type(flags) ~= "table" or flags.cmd ~= true or flags.shift ~= true then return false end
  for modifier, pressed in pairs(flags) do
    if pressed and modifier ~= "cmd" and modifier ~= "shift" then return false end
  end
  return true
end

local function fileNameCopyEventCallback(event)
  if not event or type(event.getType) ~= "function"
      or type(event.getFlags) ~= "function"
      or type(event.getKeyCode) ~= "function" then
    return false
  end
  local typeOK, eventType = pcall(event.getType, event)
  local keyOK, keyCode = pcall(event.getKeyCode, event)
  local flagsOK, flags = pcall(event.getFlags, event)
  if not typeOK or not keyOK or not flagsOK
      or eventType ~= hs.eventtap.event.types.keyDown
      or keyCode ~= 8
      or not exactFileNameCopyModifiers(flags) then
    return false
  end
  local appName = frontmostApplicationName()
  if appName ~= "Finder" and appName ~= "Cursor" then
    return false
  end
  pcall(fileNameCopy.run)
  return true
end

local function hsHotkeyBindAvailable()
  return type(hs) == "table"
    and type(hs.hotkey) == "table"
    and type(hs.hotkey.bind) == "function"
end

function M.getLastError()
  return lastError
end

function M.start()
  lastError = nil
  local bindings, loadError = loadBindings()
  if not bindings then return fail(loadError or "hotkeys_config could not be loaded") end
  if not hsHotkeyBindAvailable() then return fail("hs.hotkey.bind is unavailable") end
  if type(hs.eventtap) ~= "table"
      or type(hs.eventtap.new) ~= "function"
      or type(hs.eventtap.event) ~= "table"
      or type(hs.eventtap.event.types) ~= "table"
      or hs.eventtap.event.types.keyDown == nil then
    return fail("hs.eventtap keyDown registration is unavailable")
  end

  stopAction(aiCommands)
  stopAction(windowManagement)
  stopAction(utilityCommand)
  if fileNameCopyEventTap or #handles > 0 then stopAction(fileNameCopy) end
  if fileNameCopyEventTap then
    pcall(fileNameCopyEventTap.stop, fileNameCopyEventTap)
    pcall(fileNameCopyEventTap.delete, fileNameCopyEventTap)
    fileNameCopyEventTap = nil
  end
  deleteHandles(handles)
  handles = {}

  local newHandles = {}
  for index, binding in ipairs(bindings) do
    if binding.action.type ~= "file_name_copy" then
      local ok, handleOrError = pcall(hs.hotkey.bind, binding.modifiers, binding.key, callbackFor(binding.action))
      local handle = handleOrError
      if not ok or not handle then
        deleteHandles(newHandles)
        local reason = not ok and tostring(handleOrError) or "hs.hotkey.bind returned no handle"
        return fail("binding " .. index .. " failed: " .. reason)
      end
      newHandles[#newHandles + 1] = handle
    end
  end

  local eventTapOK, eventTapOrError = pcall(hs.eventtap.new,
    { hs.eventtap.event.types.keyDown }, fileNameCopyEventCallback)
  if not eventTapOK or not eventTapOrError then
    deleteHandles(newHandles)
    local reason = not eventTapOK and tostring(eventTapOrError) or "hs.eventtap.new returned no tap"
    return fail("file_name_copy eventtap creation failed: " .. reason)
  end
  local eventTap = eventTapOrError
  local startOK, startResult = pcall(eventTap.start, eventTap)
  if not startOK or startResult == false then
    pcall(eventTap.stop, eventTap)
    pcall(eventTap.delete, eventTap)
    deleteHandles(newHandles)
    local reason = not startOK and tostring(startResult) or "hs.eventtap.start returned false"
    return fail("file_name_copy eventtap start failed: " .. reason)
  end
  handles = newHandles
  fileNameCopyEventTap = eventTap
  return true
end

return M
