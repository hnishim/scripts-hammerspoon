local bindCalls = {}
local handles = {}
local deletedHandles = {}
local actionCalls = {}
local failAtBind = nil
local bindAttempts = 0

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTableEqual(actual, expected, message)
  assertEqual(#actual, #expected, message .. " length")
  for index, value in ipairs(expected) do
    assertEqual(actual[index], value, string.format("%s[%d]", message, index))
  end
end

local function countEntries(value)
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  return count
end

local function signature(modifiers, key)
  local normalized = {}
  for index, modifier in ipairs(modifiers) do normalized[index] = modifier end
  table.sort(normalized)
  return table.concat(normalized, "+") .. ":" .. key
end

local function recordAction(name, ...)
  actionCalls[#actionCalls + 1] = { name = name, args = { ... } }
end

local function actionStub(name)
  return { run = function(...) recordAction(name, ...) end }
end

_G.hs = {
  hotkey = {
    bind = function(modifiers, key, callback)
      bindAttempts = bindAttempts + 1
      local handle = {
        key = signature(modifiers, key),
        callback = callback,
        deleted = false,
      }
      function handle:delete()
        if not self.deleted then
          self.deleted = true
          deletedHandles[#deletedHandles + 1] = self
          if handles[self.key] == self then handles[self.key] = nil end
        end
      end
      if failAtBind == bindAttempts then
        error("injected hs.hotkey.bind failure at bind " .. bindAttempts)
      end
      bindCalls[#bindCalls + 1] = handle
      handles[handle.key] = handle
      return handle
    end,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["actions.ai_commands"] = function() return actionStub("ai") end
package.preload["actions.app_launcher"] = function() return actionStub("app") end
package.preload["actions.window_management"] = function() return actionStub("window") end
package.preload["actions.utility_command"] = function() return actionStub("utility") end
package.preload["actions.url_commands"] = function() return actionStub("url") end
package.preload["components.hud"] = function() return {} end

local home = os.getenv("HOME") or ""
local promptDir = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/prompts/ai-commands/"
local expected = {
  { { "cmd", "alt", "shift" }, "B", "ai", { promptDir .. "bio-ai_expert.md", "gemini-flash-lite-latest", "display" } },
  { { "cmd", "alt", "shift" }, "R", "ai", { promptDir .. "review-text_compact.md", "gemini-flash-lite-latest", "replace" } },
  { { "cmd", "alt", "shift" }, "T", "ai", { promptDir .. "translate.md", "gemini-flash-lite-latest", "replace" } },
}
local apps = {
  { "a", "Microsoft Teams" }, { "b", "Arc" }, { "c", "Ferdium" },
  { "d", "Cogito" }, { "e", "Cursor" }, { "f", "Finder" },
  { "i", "ChatGPT" }, { "j", "Dictionaries" }, { "k", "Linear" },
  { "m", "Meru" }, { "n", "Notion" }, { "p", "Microsoft PowerPoint" },
  { "r", "Reminders" }, { "s", "Slack" }, { "t", "Warp" },
  { "w", "1Password" }, { "x", "Microsoft Excel" }, { "z", "zoom.us" },
}
for _, appBinding in ipairs(apps) do
  local key, app = appBinding[1], appBinding[2]
  expected[#expected + 1] = { { "cmd", "ctrl", "alt", "shift" }, key, "app", { app } }
end
for index, key in ipairs({ "t", "c", "g", "r", "n", "f" }) do
  expected[#expected + 1] = { { "cmd", "ctrl" }, key,
    "window", { ({ "bottom", "center", "left", "right", "top", "full" })[index] } }
end
for _, binding in ipairs({
  { "f", "/usr/bin/osascript", home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast/two-panes-finder.applescript" },
  { "c", "/bin/bash", home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast/title-case-chicago.sh" },
}) do
  expected[#expected + 1] = { { "cmd", "alt", "shift" }, binding[1], "utility", { binding[2], binding[3] } }
end
expected[#expected + 1] = { { "ctrl", "cmd" }, "P", "window", { "previous-display" } }
expected[#expected + 1] = { { "cmd", "alt", "shift" }, "G", "url", { "google" } }
expected[#expected + 1] = { { "cmd", "alt", "shift" }, "J", "url", { "dictionary" } }

local function expectedSignatures()
  local values = {}
  for _, binding in ipairs(expected) do values[#values + 1] = signature(binding[1], binding[2]) end
  table.sort(values)
  return values
end

local function observedSignatures(firstIndex, lastIndex)
  local values = {}
  for index = firstIndex, lastIndex do values[#values + 1] = bindCalls[index].key end
  table.sort(values)
  return values
end

local hotkeys = require("hotkeys")
assert(type(hotkeys.start) == "function", "hotkeys.start() must be exported")
local firstStartOK = pcall(hotkeys.start)
assertEqual(firstStartOK, true, "first hotkeys start completes without error")
assertEqual(#bindCalls, 32, "first start registers exactly 32 hotkeys")
assertTableEqual(observedSignatures(1, 32), expectedSignatures(), "registered modifier/key combinations")

for _, binding in ipairs(expected) do
  handles[signature(binding[1], binding[2])].callback()
end
assertEqual(#actionCalls, #expected, "all registered callbacks invoke an action")
for index, binding in ipairs(expected) do
  local observed = actionCalls[index]
  assertEqual(observed.name, binding[3], "callback action module " .. index)
  assertTableEqual(observed.args, binding[4], "callback arguments " .. index)
end

local firstHandles = {}
for index = 1, 32 do firstHandles[index] = bindCalls[index] end

local reloadStartOK = pcall(hotkeys.start)
assertEqual(reloadStartOK, true, "reload hotkeys completes without error")
assertEqual(#bindCalls, 64, "reload registers a fresh set of 32 hotkeys")
assertEqual(#deletedHandles, 32, "reload deletes every previous hotkey handle")
for index, handle in ipairs(firstHandles) do
  assertEqual(handle.deleted, true, string.format("first-start handle %d is deleted", index))
end
for index = 33, 64 do
  assertEqual(bindCalls[index].deleted, false, string.format("reload handle %d remains active", index - 32))
end

local secondHandles = {}
for index = 33, 64 do secondHandles[#secondHandles + 1] = bindCalls[index] end
assertEqual(countEntries(handles), 32, "active registry contains exactly the reload handles")
for _, handle in ipairs(secondHandles) do
  assertEqual(handles[handle.key], handle, "active registry points to each reload handle")
end

-- Inject a failure by bind ordinal, independent of key ordering.
local failureBindStart = bindAttempts
failAtBind = failureBindStart + 3
local beforeFailureCount = #bindCalls
pcall(hotkeys.start)
local afterFailureCount = #bindCalls
failAtBind = nil

local failureHandles = {}
for index = beforeFailureCount + 1, #bindCalls do
  failureHandles[#failureHandles + 1] = bindCalls[index]
end
assert(#failureHandles > 0, "failure start created a partial set of new handles")
for _, handle in ipairs(failureHandles) do
  assertEqual(handle.deleted, true, "failure start deletes every partial new handle")
  assertEqual(handles[handle.key], nil, "failed start leaves no partial registry entry")
end
assert(countEntries(handles) == 0 or countEntries(handles) == 32,
  "failed start leaves either no handles or the previous complete set")

local recoveryStartOK = pcall(hotkeys.start)
assertEqual(recoveryStartOK, true, "start completes after injected failure is removed")
assertEqual(#bindCalls, afterFailureCount + 32, "recovery start registers a complete fresh set")
for index, handle in ipairs(secondHandles) do
  assertEqual(handle.deleted, true, string.format("second-start handle %d is deleted after recovery", index))
end
for index = afterFailureCount + 1, #bindCalls do
  assertEqual(bindCalls[index].deleted, false, "recovery handle remains active")
  assertEqual(handles[bindCalls[index].key], bindCalls[index],
    string.format("recovery handle %d is active in the registry", index - afterFailureCount))
end
assertEqual(countEntries(handles), 32, "recovery restores the complete active registry")

-- Loading main with action modules that fail makes an accidental multi-entrypoint
-- startup observable without inspecting source text.
package.loaded["hotkeys"] = nil
local mainStartCalls = 0
package.preload["hotkeys"] = function()
  return { start = function() mainStartCalls = mainStartCalls + 1 end }
end
for _, name in ipairs({
  "actions.ai_commands", "actions.app_launcher",
  "actions.window_management", "actions.utility_command", "actions.url_commands", "components.hud",
}) do
  package.loaded[name] = nil
  package.preload[name] = function() error("main must not load action module " .. name) end
end
package.loaded["hotkeys"] = nil
local preloadedHotkeys = require("hotkeys")
preloadedHotkeys.start()
preloadedHotkeys.start()
local mainChunk = assert(loadfile("./main.lua"))
local callsBeforeMain = mainStartCalls
_G.hs.hotkey.bind = function() error("main must not register hotkeys outside hotkeys.start") end
assert(pcall(mainChunk), "main.lua must start only through hotkeys.start()")
assertEqual(mainStartCalls - callsBeforeMain, 1, "main invokes hotkeys.start exactly once")

print("hotkeys_test: ok")
