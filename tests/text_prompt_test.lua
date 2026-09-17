local calls = {}
local mode = "submit"
local responseText = "  入力  "

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function installDialog()
  _G.hs = {
    dialog = {
      textPrompt = function(...)
        local args = { ... }
        calls[#calls + 1] = { count = select("#", ...), args = args }
        if mode == "error" then error("textPrompt failure") end
        if mode == "cancel" then return args[5] or "Cancel", responseText end
        return args[4], responseText
      end,
    },
  }
end

package.path = "./?.lua;./?/init.lua;" .. package.path
installDialog()
local textPrompt = require("components.text_prompt")

-- URL-style prompt keeps the four-argument Hammerspoon contract and trims submitted text.
calls = {}
mode = "submit"
responseText = "  検索語  "
local result = textPrompt.request({
  title = "検索",
  message = "検索語を入力してください。",
  submit = "OK",
})
assertEqual(result.status, "submitted", "URL-style submit status")
assertEqual(result.text, "検索語", "URL-style submit trims text")
assertEqual(#calls, 1, "URL-style prompt calls API once")
assertEqual(calls[1].count, 4, "URL-style prompt preserves four-argument API")
assertEqual(calls[1].args[4], "OK", "URL-style submit label")

-- AI-style prompt keeps an explicit cancel label and distinguishes cancellation.
calls = {}
mode = "cancel"
responseText = "ignored"
result = textPrompt.request({
  title = "Gemini AI command",
  message = "Geminiへ渡すテキストを入力してください。",
  submit = "実行",
  cancel = "キャンセル",
})
assertEqual(result.status, "cancelled", "AI-style cancel status")
assertEqual(result.text, nil, "cancel does not return text")
assertEqual(calls[1].count, 5, "AI-style prompt preserves five-argument API")
assertEqual(calls[1].args[5], "キャンセル", "AI-style cancel label")

-- Whitespace-only submit is an explicit empty result.
calls = {}
mode = "submit"
responseText = "   \t\n"
result = textPrompt.request({ title = "検索", message = "入力", submit = "OK" })
assertEqual(result.status, "empty", "whitespace submit is empty")
assertEqual(result.text, nil, "empty result does not expose text")

-- Hammerspoon API exceptions and absence are explicit errors, not cancellation.
calls = {}
mode = "error"
result = textPrompt.request({ title = "検索", message = "入力", submit = "OK" })
assertEqual(result.status, "error", "dialog exception is error")

_G.hs.dialog = nil
result = textPrompt.request({ title = "検索", message = "入力", submit = "OK" })
assertEqual(result.status, "error", "missing dialog API is error")

print("text_prompt_test: ok")
