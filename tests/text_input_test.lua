local focusedMode = "selected"
local selectedValue = "  raw selection  "
local promptMode = "ok"
local promptResult = { "OK", "  typed value  " }
local promptCalls = {}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function installHS()
  promptCalls = {}
  _G.hs = {
    uielement = {
      focusedElement = function()
        if focusedMode == "focused-error" then error("focusedElement failure") end
        if focusedMode == "focused-nil" then return nil end
        if focusedMode == "selected-method-missing" then return {} end
        return {
          selectedText = function(self)
            if focusedMode == "selected-error" then error("selectedText failure") end
            if focusedMode == "selected-nil" then return nil end
            if focusedMode == "selected-nonstring" then return {} end
            return selectedValue
          end,
        }
      end,
    },
    dialog = {
      textPrompt = function(...)
        local args = { n = select("#", ...), ... }
        promptCalls[#promptCalls + 1] = args
        if promptMode == "error" then error("textPrompt failure") end
        return promptResult[1], promptResult[2]
      end,
    },
  }
end

package.path = "./?.lua;./?/init.lua;" .. package.path
installHS()
package.loaded["components.text_input"] = nil
local textInput = require("components.text_input")

-- Selection acquisition preserves raw text and the focused element.
focusedMode = "selected"
selectedValue = "  raw selection  "
local selected = textInput.acquireSelection()
assertEqual(selected.status, "selected", "selection status")
assertEqual(selected.text, "  raw selection  ", "selection preserves raw text")
assert(selected.element ~= nil, "selection returns focused element")

-- Exact empty text is still a successful AX acquisition so each consumer can
-- preserve its existing empty/whitespace semantics.
selectedValue = ""
selected = textInput.acquireSelection()
assertEqual(selected.status, "selected", "exact empty selection remains acquired")
assertEqual(selected.text, "", "exact empty selection is preserved")

-- Absence and API failures remain distinguishable for URL vs AI callers.
focusedMode = "focused-nil"
local result = textInput.acquireSelection()
assertEqual(result.status, "no_focused_element", "nil focused element status")

focusedMode = "selected-nil"
result = textInput.acquireSelection()
assertEqual(result.status, "no_selection", "nil selected text status")

for _, mode in ipairs({ "focused-error", "selected-method-missing", "selected-error", "selected-nonstring" }) do
  installHS()
  focusedMode = mode
  result = textInput.acquireSelection()
  assertEqual(result.status, "error", mode .. " status")
end

installHS()
focusedMode = "selected"
_G.hs.uielement = nil
assertEqual(textInput.acquireSelection().status, "error", "missing uielement status")

installHS()
_G.hs.uielement.focusedElement = nil
assertEqual(textInput.acquireSelection().status, "error", "missing focusedElement status")

-- Prompt submission is trimmed once in the shared component.
installHS()
promptMode = "ok"
promptResult = { "OK", "  typed value  " }
result = textInput.prompt({
  title = "検索",
  message = "検索語を入力してください。",
  defaultText = "",
  submitButton = "OK",
})
assertEqual(result.status, "submitted", "prompt submit status")
assertEqual(result.text, "typed value", "prompt submit trims input")
assertEqual(promptCalls[1].n, 4, "prompt without cancel button keeps four-argument call")
assertEqual(promptCalls[1][1], "検索", "prompt title")
assertEqual(promptCalls[1][2], "検索語を入力してください。", "prompt message")
assertEqual(promptCalls[1][3], "", "prompt default text")
assertEqual(promptCalls[1][4], "OK", "prompt submit button")

-- AI prompt can keep its explicit cancel button contract.
promptResult = { "キャンセル", "ignored" }
result = textInput.prompt({
  title = "Gemini AI command",
  message = "Geminiへ渡すテキストを入力してください。",
  defaultText = "",
  submitButton = "実行",
  cancelButton = "キャンセル",
})
assertEqual(result.status, "cancelled", "prompt cancel status")
assertEqual(promptCalls[2].n, 5, "prompt with cancel button uses five-argument call")
assertEqual(promptCalls[2][4], "実行", "AI prompt submit button")
assertEqual(promptCalls[2][5], "キャンセル", "AI prompt cancel button")

for _, value in ipairs({ "", "   " }) do
  promptResult = { "OK", value }
  result = textInput.prompt({
    title = "検索",
    message = "検索語を入力してください。",
    defaultText = "",
    submitButton = "OK",
  })
  assertEqual(result.status, "empty", "empty prompt result")
end

installHS()
_G.hs.dialog = nil
result = textInput.prompt({ title = "x", message = "y", submitButton = "OK" })
assertEqual(result.status, "error", "missing dialog status")

installHS()
_G.hs.dialog.textPrompt = nil
result = textInput.prompt({ title = "x", message = "y", submitButton = "OK" })
assertEqual(result.status, "error", "missing textPrompt status")

installHS()
promptMode = "error"
result = textInput.prompt({ title = "x", message = "y", submitButton = "OK" })
assertEqual(result.status, "error", "textPrompt exception status")

-- Architecture invariant: after implementation, both consumers own only their
-- consumer-specific branching and use the shared component for AX/prompt I/O.
local function readFile(path)
  local handle = assert(io.open(path, "r"))
  local contents = assert(handle:read("*a"))
  handle:close()
  return contents
end

for _, path in ipairs({ "actions/url_commands.lua", "actions/ai_commands.lua" }) do
  local source = readFile(path)
  assert(source:find("components%.text_input"), path .. " requires shared text input")
  assert(not source:find("hs%.uielement"), path .. " does not directly access hs.uielement")
  assert(not source:find("hs%.dialog%.textPrompt"), path .. " does not directly call hs.dialog.textPrompt")
end

print("text_input_test: ok")
