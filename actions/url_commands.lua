local M = {}
local textInput = require("components.text_input")

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

local function selectedText()
  local result = textInput.acquireSelection()
  if result.status == "error" then
    alert("検索語を取得できませんでした。")
    return nil, false
  end
  if result.status == "no_focused_element" or result.status == "no_selection" then
    return nil, true
  end
  if result.status ~= "selected" then
    alert("検索語を取得できませんでした。")
    return nil, false
  end

  local value = trimmed(result.text)
  if value == "" then return nil, true end
  return value, true
end

local function inputText()
  local result = textInput.prompt({
    title = "検索",
    message = "検索語を入力してください。",
    defaultText = "",
    submitButton = "OK",
  })
  if result.status == "error" then
    alert("検索語を入力できませんでした。")
    return nil
  end
  if result.status == "cancelled" or result.status == "empty" then
    alert("検索をキャンセルしました。")
    return nil
  end
  if result.status ~= "submitted" then
    alert("検索語を入力できませんでした。")
    return nil
  end
  return result.text
end

function M.run(command)
  local value, canPrompt = selectedText()
  if not canPrompt then return false end
  if not value then value = inputText() end
  if not value then return false end

  local prefix
  if command == "google" then
    prefix = GOOGLE_URL
  elseif command == "dictionary" then
    prefix = DICTIONARY_URL
  else
    alert("URLコマンドを実行できませんでした。")
    return false
  end

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

return M
