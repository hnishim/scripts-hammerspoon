local alerts = {}
local openedURLs = {}
local captureCalls = {}
local promptCalls = {}
local selectionResult = { status = "selected", text = "選択語" }
local promptResult = { status = "submitted", text = "入力語" }
local openMode = "ok"

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertURL(expected, message)
  assertEqual(#openedURLs, 1, message .. " opens exactly one URL")
  assertEqual(openedURLs[1], expected, message .. " URL")
end

local function resetCalls()
  alerts, openedURLs, captureCalls, promptCalls = {}, {}, {}, {}
  openMode = "ok"
end

_G.hs = {
  alert = {
    show = function(message) alerts[#alerts + 1] = message end,
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

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["components.text_io"] = function()
  return {
    capture = function(mode, callback)
      captureCalls[#captureCalls + 1] = mode
      callback(selectionResult)
      return true
    end,
  }
end
package.preload["components.text_prompt"] = function()
  return {
    request = function(options)
      promptCalls[#promptCalls + 1] = options
      return promptResult
    end,
  }
end

local urlCommands = require("actions.url_commands")

-- URL commands always acquire through the shared read I/O boundary.
selectionResult = { status = "selected", text = "a b&c?" }
assert(urlCommands.run("google") ~= false, "Google selected-text run starts")
assertEqual(#captureCalls, 1, "Google uses one shared capture")
assertEqual(captureCalls[1], "read", "Google uses read mode")
assertEqual(#promptCalls, 0, "selected text does not prompt")
assertURL("https://www.google.com/search?q=a%20b%26c%3F", "Google selected-text")

resetCalls()
selectionResult = { status = "selected", text = "日本語" }
assert(urlCommands.run("dictionary") ~= false, "dictionary selected-text run starts")
assertEqual(captureCalls[1], "read", "dictionary uses read mode")
assertURL("mkdictionaries:///?text=%E6%97%A5%E6%9C%AC%E8%AA%9E&category=en-ja&scope=headword", "dictionary selected-text")

-- No selection is the only acquisition result that is allowed to enter manual input.
resetCalls()
selectionResult = { status = "none" }
promptResult = { status = "submitted", text = "空 白 日本語&?#" }
assert(urlCommands.run("google") ~= false, "no-selection run starts")
assertEqual(#promptCalls, 1, "no selection prompts exactly once")
assertURL("https://www.google.com/search?q=%E7%A9%BA%20%E7%99%BD%20%E6%97%A5%E6%9C%AC%E8%AA%9E%26%3F%23", "manual input")

for _, status in ipairs({ "cancelled", "empty", "error" }) do
  resetCalls()
  selectionResult = { status = "none" }
  promptResult = { status = status }
  urlCommands.run("google")
  assertEqual(#promptCalls, 1, "prompt terminal state calls prompt once: " .. status)
  assertEqual(#openedURLs, 0, "prompt terminal state opens no URL: " .. status)
  assert(#alerts > 0, "prompt terminal state alerts: " .. status)
end

-- Acquisition failures never fall through to manual input.
for _, status in ipairs({ "unavailable", "error" }) do
  resetCalls()
  selectionResult = { status = status }
  promptResult = { status = "submitted", text = "must not be used" }
  urlCommands.run("google")
  assertEqual(#promptCalls, 0, "acquisition failure never prompts: " .. status)
  assertEqual(#openedURLs, 0, "acquisition failure opens no URL: " .. status)
  assert(#alerts > 0, "acquisition failure alerts: " .. status)
end

-- URL failures are still owned by the URL command, not the shared text I/O layer.
resetCalls()
selectionResult = { status = "selected", text = "query" }
openMode = "false"
urlCommands.run("google")
assertEqual(#openedURLs, 1, "URL false result attempts one open")
assert(#alerts > 0, "URL false result alerts")

resetCalls()
selectionResult = { status = "selected", text = "query" }
openMode = "exception"
urlCommands.run("google")
assertEqual(#openedURLs, 1, "URL exception attempts one open")
assert(#alerts > 0, "URL exception alerts")

-- Invalid command is rejected before text acquisition.
resetCalls()
assertEqual(urlCommands.run("unknown"), false, "invalid command is rejected")
assertEqual(#captureCalls, 0, "invalid command does not acquire text")
assertEqual(#openedURLs, 0, "invalid command opens no URL")
assert(#alerts > 0, "invalid command alerts")

print("url_commands_test: ok")
