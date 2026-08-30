local M = {}

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
  if not hs.uielement or type(hs.uielement.focusedElement) ~= "function" then
    alert("検索語を取得できませんでした。")
    return nil, false
  end
  local focusedOK, focused = pcall(hs.uielement.focusedElement)
  if not focusedOK then
    alert("検索語を取得できませんでした。")
    return nil, false
  end
  if focused == nil then return nil, true end
  if type(focused.selectedText) ~= "function" then
    alert("検索語を取得できませんでした。")
    return nil, false
  end
  local selectedOK, value = pcall(focused.selectedText, focused)
  if not selectedOK or (value ~= nil and type(value) ~= "string") then
    alert("検索語を取得できませんでした。")
    return nil, false
  end
  if value == nil or trimmed(value) == "" then return nil, true end
  return trimmed(value), true
end

local function inputText()
  if not hs.dialog or type(hs.dialog.textPrompt) ~= "function" then
    alert("検索語を入力できませんでした。")
    return nil
  end
  local ok, button, value = pcall(hs.dialog.textPrompt, "検索", "検索語を入力してください。", "", "OK")
  if not ok then
    alert("検索語を入力できませんでした。")
    return nil
  end
  value = trimmed(value)
  if button ~= "OK" or value == "" then
    alert("検索をキャンセルしました。")
    return nil
  end
  return value
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
