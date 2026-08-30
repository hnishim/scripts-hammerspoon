local alerts = {}
local prompts = {}
local openedURLs = {}
local focusedMode = "selected"
local selectedValue = "選択語"
local promptResult = { "OK", "入力語" }
local promptMode = "ok"
local openMode = "ok"

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertURL(expected, message)
  assertEqual(#openedURLs, 1, message .. " opens exactly one URL")
  assertEqual(openedURLs[1], expected, message .. " URL")
end

local function resetCalls()
  alerts, prompts, openedURLs = {}, {}, {}
end

local function installHS()
  _G.hs = {
    alert = {
      show = function(message) alerts[#alerts + 1] = message end,
    },
    uielement = {
      focusedElement = function()
        if focusedMode == "lookup-error" then error("focusedElement failure") end
        if focusedMode == "missing" or focusedMode == "nil" then return nil end
        return {
          selectedText = function()
            if focusedMode == "selected-error" then error("selectedText failure") end
            if focusedMode == "selected-missing" then return nil end
            if focusedMode == "selected-absent" then return {} end
            return selectedValue
          end,
        }
      end,
    },
    dialog = {
      textPrompt = function(title, message, defaultText, button)
        prompts[#prompts + 1] = { title, message, defaultText, button }
        if promptMode == "missing" then error("textPrompt failure") end
        if promptMode == "exception" then error("textPrompt exception") end
        return promptResult[1], promptResult[2]
      end,
    },
    urlevent = {
      openURL = function(url)
        openedURLs[#openedURLs + 1] = url
        if openMode == "exception" then error("openURL failure") end
        if openMode == "false" then return false end
        return true
      end,
    },
  }
end

package.path = "./?.lua;./?/init.lua;" .. package.path
installHS()
local urlCommands = require("actions.url_commands")

-- Selection is preferred, and each command has one URL side effect.
selectedValue = "a b&c?"
assertEqual(urlCommands.run("google"), true, "Google selected-text run succeeds")
assertURL("https://www.google.com/search?q=a%20b%26c%3F", "Google selected-text")
resetCalls()
selectedValue = "AZaz09-._~"
assertEqual(urlCommands.run("google"), true, "unreserved query characters run succeeds")
assertURL("https://www.google.com/search?q=AZaz09-._~", "unreserved query characters")
resetCalls()
selectedValue = "日本語"
assertEqual(urlCommands.run("dictionary"), true, "dictionary selected-text run succeeds")
assertURL("mkdictionaries:///?text=%E6%97%A5%E6%9C%AC%E8%AA%9E&category=en-ja&scope=headword", "dictionary selected-text")

-- A nil focused element or nil/empty selection falls through to text input.
for _, mode in ipairs({ "nil", "selected-missing" }) do
  resetCalls()
  focusedMode = mode
  promptMode = "ok"
  promptResult = { "OK", "空 白 日本語&?#" }
  assertEqual(urlCommands.run("google"), true, "input fallback succeeds for " .. mode)
  assertEqual(#prompts, 1, "input fallback shows one dialog for " .. mode)
  assertURL("https://www.google.com/search?q=%E7%A9%BA%20%E7%99%BD%20%E6%97%A5%E6%9C%AC%E8%AA%9E%26%3F%23", "input fallback " .. mode)
end

-- Empty selected text also uses the dialog; cancel and empty input do not open URLs.
for _, value in ipairs({ "", "   " }) do
  resetCalls()
  focusedMode, selectedValue = "selected", value
  promptResult = { "OK", "入力" }
  assertEqual(urlCommands.run("dictionary"), true, "empty selection input fallback succeeds")
  assertEqual(#prompts, 1, "empty selection shows one dialog")
  assertEqual(#openedURLs, 1, "empty selection opens one URL after input")
end
for _, result in ipairs({ { "Cancel", "入力" }, { "OK", "" }, { "OK", "   " } }) do
  resetCalls()
  focusedMode, selectedValue, promptResult = "nil", "", result
  assertEqual(urlCommands.run("google"), false, "cancel/empty input does not run")
  assertEqual(#prompts, 1, "cancel/empty input shows one dialog")
  assertEqual(#openedURLs, 0, "cancel/empty input does not open URL")
  assert(#alerts > 0, "cancel/empty input alerts")
end

-- Missing or failing selection APIs are errors, not an invitation to prompt.
for _, mode in ipairs({ "lookup-error", "selected-error", "selected-absent" }) do
  resetCalls()
  focusedMode = mode
  assertEqual(urlCommands.run("google"), false, "selection API failure does not run")
  assertEqual(#prompts, 0, "selection API failure does not prompt")
  assertEqual(#openedURLs, 0, "selection API failure does not open URL")
  assert(#alerts > 0, "selection API failure alerts")
end

-- Dialog and URL failures stop without a second side effect and alert the user.
focusedMode = "nil"
for _, mode in ipairs({ "missing", "exception" }) do
  resetCalls(); promptMode = mode
  assertEqual(urlCommands.run("google"), false, "dialog failure does not run")
  assertEqual(#openedURLs, 0, "dialog failure does not open URL")
  assert(#alerts > 0, "dialog failure alerts")
end
resetCalls(); promptMode = "ok"; promptResult = { "OK", "query" }; openMode = "ok"
_G.hs.dialog = nil
assertEqual(urlCommands.run("google"), false, "missing dialog API does not run")
assertEqual(#openedURLs, 0, "missing dialog API does not open URL")
assert(#alerts > 0, "missing dialog API alerts")
installHS(); focusedMode = "nil"
for _, mode in ipairs({ "exception", "false" }) do
  resetCalls(); promptMode = "ok"; promptResult = { "OK", "query" }; openMode = mode
  assertEqual(urlCommands.run("google"), false, "URL failure does not run")
  assertEqual(#openedURLs, 1, "URL failure attempts exactly one open")
  assert(#alerts > 0, "URL failure alerts")
end
resetCalls(); openMode = "ok"; promptMode = "ok"; promptResult = { "OK", "query" }
_G.hs.urlevent = nil
assertEqual(urlCommands.run("google"), false, "missing URL API does not run")
assertEqual(#openedURLs, 0, "missing URL API does not open URL")
assert(#alerts > 0, "missing URL API alerts")

-- API absence is handled like an API failure.
resetCalls(); openMode = "ok"; promptMode = "ok"; focusedMode = "nil"
_G.hs.uielement = nil
assertEqual(urlCommands.run("google"), false, "missing focusedElement API does not run")
assertEqual(#prompts, 0, "missing focusedElement API does not prompt")
assert(#alerts > 0, "missing focusedElement API alerts")

local function assertMissingAPIFails(label)
  local ok, result = pcall(urlCommands.run, "google")
  assertEqual(ok, true, label .. " does not raise")
  assertEqual(result, false, label .. " returns failure")
  assertEqual(#openedURLs, 0, label .. " does not open URL")
  assert(#alerts > 0, label .. " alerts")
end

-- Each API method's absence is covered independently and never falls through.
installHS(); resetCalls(); focusedMode = "selected"
_G.hs.uielement.focusedElement = nil
assertMissingAPIFails("focusedElement absence")

installHS(); resetCalls(); focusedMode = "selected"
_G.hs.uielement.focusedElement = function() return {} end
assertMissingAPIFails("element.selectedText absence")

installHS(); resetCalls(); focusedMode = "nil"
_G.hs.dialog.textPrompt = nil
assertMissingAPIFails("dialog.textPrompt absence")

installHS(); resetCalls(); focusedMode = "selected"; selectedValue = "query"
_G.hs.urlevent.openURL = nil
assertMissingAPIFails("urlevent.openURL absence")

print("url_commands_test: ok")
