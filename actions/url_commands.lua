local M = {}
local textIO = require("components.text_io")
local textPrompt = require("components.text_prompt")
local pendingInput

local GOOGLE_URL = "https://www.google.com/search?q="
local DICTIONARY_URL = "mkdictionaries:///?text="
local DICTIONARY_SUFFIX = "&category=en-ja&scope=headword"

local function alert(message)
  if hs.alert and hs.alert.show then pcall(hs.alert.show, message, 2) end
end

local function trimmed(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function encodeQuery(value)
  return (value:gsub(".", function(character)
    local byte = string.byte(character)
    if (byte >= 48 and byte <= 57)
      or (byte >= 65 and byte <= 90)
      or (byte >= 97 and byte <= 122)
      or character == "-" or character == "." or character == "_" or character == "~" then
      return character
    end
    return string.format("%%%02X", byte)
  end))
end

local function open(command, value)
  local prefix = command == "google" and GOOGLE_URL or DICTIONARY_URL
  if not hs.urlevent or type(hs.urlevent.openURL) ~= "function" then
    alert("Could not open the URL.")
    return false
  end
  local suffix = command == "dictionary" and DICTIONARY_SUFFIX or ""
  local ok, result = pcall(hs.urlevent.openURL, prefix .. encodeQuery(value) .. suffix)
  if not ok or result == false then
    alert("Could not open the URL.")
    return false
  end
  return true
end

local function prompt(command)
  if pendingInput then return false end
  local entry = { done = false }
  pendingInput = entry
  local function complete(result)
    if pendingInput ~= entry or entry.done then return end
    entry.done = true
    pendingInput = nil
    if type(result) == "table" and result.status == "submitted" then
      open(command, result.text)
    elseif type(result) == "table" and result.status == "error" then
      alert("Could not open the search input.")
    elseif type(result) == "table" and result.status == "empty" then
      alert("Search input is empty.")
    elseif type(result) == "table" and result.status == "cancelled" then
      alert("Search cancelled.")
    else
      alert("Could not open the search input.")
    end
  end
  local ok, started = pcall(textPrompt.request, {
    title = "Search",
    message = "Enter search terms.",
    submit = "Search",
    cancel = "Cancel",
  }, complete)
  if not ok or started == false then
    if pendingInput == entry then complete({ status = "error" }) end
    return false
  end
  return true
end

function M.run(command)
  if command ~= "google" and command ~= "dictionary" then
    alert("Could not run the URL command.")
    return false
  end

  if pendingInput then return false end
  local started = textIO.capture("read", function(result)
    if type(result) ~= "table" then alert("Could not read search terms."); return end
    if result.status == "selected" then
      local value = trimmed(result.text)
      if value ~= "" then open(command, value) else prompt(command) end
      return
    end
    if result.status == "none" then prompt(command); return end
    alert("Could not read search terms.")
  end)
  if started == false then return false end
  return true
end

return M
