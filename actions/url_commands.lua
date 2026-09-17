local M = {}
local textIO = require("components.text_io")
local textPrompt = require("components.text_prompt")

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
    alert("URLを開けませんでした。")
    return false
  end
  local suffix = command == "dictionary" and DICTIONARY_SUFFIX or ""
  local ok, result = pcall(hs.urlevent.openURL, prefix .. encodeQuery(value) .. suffix)
  if not ok or result == false then
    alert("URLを開けませんでした。")
    return false
  end
  return true
end

local function prompt(command)
  local result = textPrompt.request({
    title = "検索",
    message = "検索語を入力してください。",
    submit = "OK",
  })
  if result.status == "submitted" then return open(command, result.text) end
  if result.status == "error" then alert("検索語を入力できませんでした。")
  else alert("検索をキャンセルしました。") end
  return false
end

function M.run(command)
  if command ~= "google" and command ~= "dictionary" then
    alert("URLコマンドを実行できませんでした。")
    return false
  end

  local started = textIO.capture("read", function(result)
    if type(result) ~= "table" then alert("検索語を取得できませんでした。"); return end
    if result.status == "selected" then
      local value = trimmed(result.text)
      if value ~= "" then open(command, value) else prompt(command) end
      return
    end
    if result.status == "none" then prompt(command); return end
    alert("検索語を取得できませんでした。")
  end)
  if started == false then return false end
  return true
end

return M
