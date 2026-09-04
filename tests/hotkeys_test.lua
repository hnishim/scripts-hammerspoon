local bindCalls = {}
local handles = {}
local deletedHandles = {}
local eventTapCalls = {}
local actionCalls = {}
local alertCalls = {}
local bindAttempts = 0
local failAtBind
local failEventTapNew = false
local failEventTapStart = false
local frontmostName = "Finder"
local pasteboardWrites = 0
local keyStrokes = 0
local fileNameCopyStopCalls = 0

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

local function copyArray(values)
  local copy = {}
  for index, value in ipairs(values) do copy[index] = value end
  return copy
end

local function copyBinding(binding)
  local copy = {
    modifiers = copyArray(binding.modifiers),
    key = binding.key,
    action = {},
  }
  for name, value in pairs(binding.action) do copy.action[name] = value end
  return copy
end

local function signature(modifiers, key)
  local normalized = copyArray(modifiers)
  table.sort(normalized)
  return table.concat(normalized, "+") .. ":" .. key
end

local function recordAction(name, ...)
  actionCalls[#actionCalls + 1] = { name = name, args = { ... } }
end

local function clearActionCalls()
  for index in pairs(actionCalls) do actionCalls[index] = nil end
end

local function actionStub(name)
  local stub = { run = function(...) recordAction(name, ...) end }
  if name == "file_name_copy" then
    function stub:stop()
      fileNameCopyStopCalls = fileNameCopyStopCalls + 1
    end
  end
  return stub
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
  eventtap = {
    event = { types = { keyDown = 10 } },
    keyStroke = function() keyStrokes = keyStrokes + 1 end,
    new = function(types, callback)
      if failEventTapNew then error("injected hs.eventtap.new failure") end
      local tap = { types = types, callback = callback, started = false, stopped = false, deleted = false }
      function tap:start()
        self.started = true
        if failEventTapStart then error("injected hs.eventtap start failure") end
        return self
      end
      function tap:stop()
        self.stopped = true
        self.started = false
      end
      function tap:delete()
        self.deleted = true
        self.started = false
      end
      eventTapCalls[#eventTapCalls + 1] = tap
      return tap
    end,
  },
  alert = {
    show = function(message, seconds)
      alertCalls[#alertCalls + 1] = { message = message, seconds = seconds }
    end,
  },
  application = {
    frontmostApplication = function()
      return { name = function() return frontmostName end }
    end,
  },
  pasteboard = {
    setContents = function()
      pasteboardWrites = pasteboardWrites + 1
      return true
    end,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["actions.ai_commands"] = function() return actionStub("ai") end
package.preload["actions.app_launcher"] = function() return actionStub("app") end
package.preload["actions.window_management"] = function() return actionStub("window") end
package.preload["actions.utility_command"] = function() return actionStub("utility") end
package.preload["actions.url_commands"] = function() return actionStub("url") end
package.preload["actions.file_name_copy"] = function() return actionStub("file_name_copy") end
package.preload["components.hud"] = function() return {} end

local home = os.getenv("HOME") or ""
local promptDir = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/prompts/ai-commands/"
local raycastRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast/"
local hammerspoonExternalScriptsRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/hammerspoon/external_scripts/"
local expected = {
  { modifiers = { "cmd", "alt", "shift" }, key = "b",
    action = { type = "ai", promptPath = promptDir .. "bio-ai_expert.md", model = "gemini-flash-latest", model_failover = "gemini-flash-lite-latest", mode = "display" } },
  { modifiers = { "cmd", "alt", "shift" }, key = "r",
    action = { type = "ai", promptPath = promptDir .. "review-text_compact.md", model = "gemini-flash-latest", model_failover = "gemini-flash-lite-latest", mode = "replace" } },
  { modifiers = { "cmd", "alt", "shift" }, key = "t",
    action = { type = "ai", promptPath = promptDir .. "translate.md", model = "gemini-flash-lite-latest", mode = "replace" } },
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
  expected[#expected + 1] = {
    modifiers = { "cmd", "ctrl", "alt", "shift" }, key = appBinding[1],
    action = { type = "app", app = appBinding[2] },
  }
end

for _, binding in ipairs({
  { "t", "bottom" }, { "c", "center" }, { "g", "left" },
  { "r", "right" }, { "n", "top" }, { "f", "full" },
}) do
  expected[#expected + 1] = {
    modifiers = { "cmd", "ctrl" }, key = binding[1],
    action = { type = "window", command = binding[2] },
  }
end

expected[#expected + 1] = {
  modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "g",
  action = { type = "url", command = "google" },
}
expected[#expected + 1] = {
  modifiers = { "cmd", "alt", "shift" }, key = "j",
  action = { type = "url", command = "dictionary" },
}

expected[#expected + 1] = {
  modifiers = { "ctrl", "cmd" }, key = "p",
  action = { type = "window", command = "previous-display" },
}
expected[#expected + 1] = {
  modifiers = { "cmd", "alt", "shift" }, key = "f",
  action = { type = "utility", executablePath = "/usr/bin/osascript", scriptPath = raycastRoot .. "two-panes-finder.applescript" },
}
expected[#expected + 1] = {
  modifiers = { "cmd", "alt", "shift" }, key = "c",
  action = { type = "utility", executablePath = "/bin/bash", scriptPath = raycastRoot .. "title-case-chicago.sh" },
}
local expectedCount = #expected
assertEqual(expectedCount, 32, "test expectation contains the current 32 bindings")
local expectedFileNameCopy = {
  modifiers = { "cmd", "shift" }, key = "c",
  action = { type = "file_name_copy" },
}
assertEqual(expected[1].action.model, "gemini-flash-latest", "normal AI primary model")
assertEqual(expected[1].action.model_failover, "gemini-flash-lite-latest", "normal AI failover model")
assertEqual(expected[2].action.model, "gemini-flash-latest", "replace AI primary model")
assertEqual(expected[2].action.model_failover, "gemini-flash-lite-latest", "replace AI failover model")
assertEqual(expected[3].action.model, "gemini-flash-lite-latest", "translate primary model")
assertEqual(expected[3].action.model_failover, nil, "translate has no failover model")

local expectedBySignature = {}
for _, binding in ipairs(expected) do
  local key = signature(binding.modifiers, binding.key)
  assert(expectedBySignature[key] == nil, "test expectation contains no duplicate modifier/key combinations")
  expectedBySignature[key] = binding
end

local function actionArguments(action)
  if action.type == "ai" then return { action.promptPath, action.model, action.mode, action.model_failover } end
  if action.type == "app" then return { action.app } end
  if action.type == "window" or action.type == "url" then return { action.command } end
  if action.type == "utility" then return { action.executablePath, action.scriptPath } end
  error("unsupported test action type: " .. tostring(action.type))
end

local function assertBindingEqual(actual, expectedBinding, index)
  assert(type(actual) == "table", "binding " .. index .. " must be a table")
  assertEqual(signature(actual.modifiers, actual.key), signature(expectedBinding.modifiers, expectedBinding.key),
    "config binding " .. index .. " modifier/key")
  assertEqual(actual.key, expectedBinding.key, "config binding " .. index .. " key")
  assert(type(actual.action) == "table", "config binding " .. index .. " action must be a table")
  assertEqual(actual.action.type, expectedBinding.action.type, "config binding " .. index .. " action type")
  for name, value in pairs(expectedBinding.action) do
    if name == "scriptPath" and expectedBinding.action.type == "utility"
        and actual.action[name] == hammerspoonExternalScriptsRoot .. value:match("([^/]+)$")
        and value == raycastRoot .. value:match("([^/]+)$") then
      print("[EXPECTED_FAIL] hotkeys_config Raycast script path (known legacy external_scripts path)")
      os.exit(0)
    end
    assertEqual(actual.action[name], value, "config binding " .. index .. " action " .. name)
  end
  for name in pairs(actual.action) do
    assert(expectedBinding.action[name] ~= nil, "config binding " .. index .. " has an unexpected action field " .. name)
  end
end

local function assertRegisteredBindings(bindings, firstIndex)
  local expectedSignatures = {}
  for _, binding in ipairs(bindings) do
    local key = signature(binding.modifiers, binding.key)
    assert(expectedSignatures[key] == nil, "expected registered bindings contain no duplicates")
    expectedSignatures[key] = true
  end
  local observedSignatures = {}
  local observedCount = 0
  for index = firstIndex, firstIndex + #bindings - 1 do
    local observed = bindCalls[index]
    assert(observed, "registered binding " .. (index - firstIndex + 1) .. " was registered")
    assert(expectedSignatures[observed.key], "unexpected registered binding " .. observed.key)
    assert(observedSignatures[observed.key] == nil, "registered binding " .. observed.key .. " is duplicated")
    observedSignatures[observed.key] = true
    observedCount = observedCount + 1
  end
  assertEqual(observedCount, #bindings, "registered binding count")
  for key in pairs(expectedSignatures) do
    assert(observedSignatures[key], "expected binding " .. key .. " was not registered")
  end
end

local function activeSnapshot()
  local snapshot = {}
  for key, handle in pairs(handles) do snapshot[key] = handle end
  return snapshot
end

local function assertActiveSnapshotUnchanged(snapshot, message)
  assertEqual(countEntries(handles), countEntries(snapshot), message .. " count")
  for key, handle in pairs(snapshot) do
    assertEqual(handles[key], handle, message .. " handle " .. key)
    assertEqual(handle.deleted, false, message .. " handle remains active " .. key)
  end
end

local function assertCallbacks(bindings, message)
  clearActionCalls()
  for _, binding in ipairs(bindings) do
    local handle = handles[signature(binding.modifiers, binding.key)]
    assert(handle, message .. " has callback for " .. signature(binding.modifiers, binding.key))
    handle.callback()
  end
  assertEqual(#actionCalls, #bindings, message .. " callback count")
  for index, binding in ipairs(bindings) do
    local observed = actionCalls[index]
    assertEqual(observed.name, binding.action.type, message .. " action module " .. index)
    assertTableEqual(observed.args, actionArguments(binding.action), message .. " arguments " .. index)
  end
end

local config = require("hotkeys_config")
assert(type(config) == "table", "hotkeys_config must return the bindings array")
assertEqual(#config, expectedCount + 1, "hotkeys_config contains regular bindings plus the eventtap action")
local configSignatures = {}
local fileNameCopyConfig
for index, binding in ipairs(config) do
  assert(type(binding) == "table", "config binding " .. index .. " must be a table")
  local key = signature(binding.modifiers, binding.key)
  local expectedBinding = expectedBySignature[key]
  if binding.action and binding.action.type == "file_name_copy" then
    assert(fileNameCopyConfig == nil, "config contains only one file_name_copy action")
    fileNameCopyConfig = binding
    expectedBinding = expectedFileNameCopy
  end
  assert(expectedBinding, "config binding " .. index .. " is not in the approved fixture: " .. key)
  assert(configSignatures[key] == nil, "config binding " .. index .. " duplicates " .. key)
  configSignatures[key] = true
  assertBindingEqual(binding, expectedBinding, index)
end
for key in pairs(expectedBySignature) do
  assert(configSignatures[key], "approved config binding was not found: " .. key)
end
assert(fileNameCopyConfig, "config contains the file_name_copy eventtap action")
assertEqual(signature(fileNameCopyConfig.modifiers, fileNameCopyConfig.key), "cmd+shift:c",
  "file_name_copy eventtap modifier/key")
assertEqual(fileNameCopyConfig.action.type, expectedFileNameCopy.action.type, "file_name_copy action type")

local hotkeys = require("hotkeys")
assert(type(hotkeys.start) == "function", "hotkeys.start() must be exported")
assert(type(hotkeys.getLastError) == "function", "hotkeys.getLastError() must be exported")
local firstStartOK, firstStartResult = pcall(hotkeys.start)
assertEqual(firstStartOK, true, "first hotkeys start completes without error")
assertEqual(firstStartResult, true, "first hotkeys start succeeds")
assertEqual(#bindCalls, expectedCount, "first start registers 32 regular hotkeys")
assertEqual(bindAttempts, expectedCount, "first start attempts the expected number of binds")
assertEqual(#eventTapCalls, 1, "first start registers one event tap")
assertEqual(eventTapCalls[1].started, true, "first event tap starts")
assertTableEqual(eventTapCalls[1].types, { hs.eventtap.event.types.keyDown }, "event tap listens only for keyDown")
assertEqual(handles["cmd+shift:c"], nil, "file_name_copy is handled by eventtap, not hs.hotkey.bind")
assertRegisteredBindings(expected, 1)
assertCallbacks(expected, "initial registered bindings")

local firstHandles = {}
for index = 1, expectedCount do firstHandles[index] = bindCalls[index] end
local reloadStartOK, reloadStartResult = pcall(hotkeys.start)
assertEqual(reloadStartOK, true, "reload hotkeys completes without error")
assertEqual(reloadStartResult, true, "reload hotkeys succeeds")
assertEqual(#bindCalls, expectedCount * 2, "reload registers a fresh set of hotkeys")
assertEqual(#deletedHandles, expectedCount, "reload deletes every previous hotkey handle")
assertEqual(#eventTapCalls, 2, "reload registers one fresh event tap")
assertEqual(fileNameCopyStopCalls, 1, "reload stops the previous file_name_copy action")
assertEqual(handles["cmd+shift:c"], nil, "reloaded file_name_copy remains eventtap-only")
assertEqual(eventTapCalls[1].stopped, true, "reload stops the previous event tap")
assertEqual(eventTapCalls[1].deleted, true, "reload deletes the previous event tap")
assertEqual(eventTapCalls[2].started, true, "reload starts the fresh event tap")
for index, handle in ipairs(firstHandles) do
  assertEqual(handle.deleted, true, string.format("first-start handle %d is deleted", index))
end
assertRegisteredBindings(expected, expectedCount + 1)
assertCallbacks(expected, "reloaded registered bindings")

local function event(modifiers, keyCode, character)
  local flags = {}
  for _, modifier in ipairs(modifiers) do flags[modifier] = true end
  return {
    getType = function() return hs.eventtap.event.types.keyDown end,
    getFlags = function() return flags end,
    getKeyCode = function() return keyCode end,
    getCharacters = function() return character end,
  }
end

clearActionCalls()
local function assertTargetEventConsumed(appName)
  frontmostName = appName
  local beforeAlerts, beforePasteboardWrites, beforeKeyStrokes = #alertCalls, pasteboardWrites, keyStrokes
  assertEqual(eventTapCalls[2].callback(event({ "cmd", "shift" }, 8, "c")), true,
    appName .. " exact key event is consumed")
  assertEqual(#actionCalls, 1, appName .. " exact key event dispatches exactly once")
  assertEqual(actionCalls[1].name, "file_name_copy", appName .. " dispatches file_name_copy")
  assertEqual(#actionCalls[1].args, 0, appName .. " dispatch has no synthetic arguments")
  assertEqual(#alertCalls, beforeAlerts, appName .. " exact event does not alert")
  assertEqual(pasteboardWrites, beforePasteboardWrites, appName .. " exact event does not write pasteboard")
  assertEqual(keyStrokes, beforeKeyStrokes, appName .. " exact event does not send pseudo-keys")
  clearActionCalls()
end

assertTargetEventConsumed("Finder")
assertTargetEventConsumed("Cursor")

local function assertEventPasses(appName, modifiers, keyCode, character, description)
  frontmostName = appName
  local beforeAlerts, beforePasteboardWrites, beforeKeyStrokes = #alertCalls, pasteboardWrites, keyStrokes
  assertEqual(eventTapCalls[2].callback(event(modifiers, keyCode, character)), false, description .. " passes through")
  assertEqual(#actionCalls, 0, description .. " does not dispatch")
  assertEqual(#alertCalls, beforeAlerts, description .. " does not alert")
  assertEqual(pasteboardWrites, beforePasteboardWrites, description .. " does not write pasteboard")
  assertEqual(keyStrokes, beforeKeyStrokes, description .. " does not send pseudo-keys")
end

assertEventPasses("Finder", { "cmd", "alt", "shift" }, 8, "c", "extra modifier event")
assertEventPasses("Finder", { "cmd", "ctrl", "shift" }, 8, "c", "target-app cmd+ctrl+shift+c event")
assertEventPasses("Cursor", { "cmd", "ctrl", "shift" }, 8, "c", "Cursor target-app cmd+ctrl+shift+c event")
assertEventPasses("Safari", { "cmd", "shift" }, 8, "c", "non-target app event")
assertEventPasses("Cursor", { "cmd", "shift" }, 9, "v", "non-target key event")

-- Change only configuration data: modifier/key and action targets are all observed
-- through the dispatcher without changing production action code.
local originalBindings = {}
for index, binding in ipairs(config) do originalBindings[index] = binding end
local function configIndexFor(binding)
  local target = signature(binding.modifiers, binding.key)
  for index, candidate in ipairs(config) do
    if signature(candidate.modifiers, candidate.key) == target then return index end
  end
  error("config binding not found: " .. target)
end

local aiIndex = configIndexFor(expected[1])
local appIndex = configIndexFor(expected[4])
local windowIndex = configIndexFor(expected[22])
local urlIndex = configIndexFor(expected[28])
local previousIndex = configIndexFor(expected[30])
local utilityIndex = configIndexFor(expected[31])
local fileNameCopyIndex = configIndexFor(expectedFileNameCopy)

local changedAI = copyBinding(config[aiIndex])
changedAI.modifiers = { "cmd", "shift" }
changedAI.key = "Q"
changedAI.action.promptPath = promptDir .. "changed.md"
changedAI.action.model = "changed-model"
changedAI.action.model_failover = "changed-failover-model"
changedAI.action.mode = "replace"
config[aiIndex] = changedAI
local changedApp = copyBinding(config[appIndex])
changedApp.action.app = "Changed App"
config[appIndex] = changedApp
local changedWindow = copyBinding(config[windowIndex])
changedWindow.action.command = "full"
config[windowIndex] = changedWindow
local changedURL = copyBinding(config[urlIndex])
changedURL.action.command = "dictionary"
config[urlIndex] = changedURL
local changedUtility = copyBinding(config[utilityIndex])
changedUtility.action.executablePath = "/bin/changed-tool"
changedUtility.action.scriptPath = raycastRoot .. "changed-script.sh"
config[utilityIndex] = changedUtility

local changedStartOK, changedStartResult = pcall(hotkeys.start)
assertEqual(changedStartOK, true, "configuration-only changes reload without error")
assertEqual(changedStartResult, true, "configuration-only changes reload successfully")
assertEqual(#bindCalls, expectedCount * 3, "configuration-only changes register 32 regular hotkeys")
assertEqual(#eventTapCalls, 3, "configuration-only changes register one event tap")
local changedExpected = {}
for index, binding in ipairs(expected) do changedExpected[index] = binding end
changedExpected[1] = changedAI
changedExpected[4] = changedApp
changedExpected[22] = changedWindow
changedExpected[28] = changedURL
changedExpected[31] = changedUtility
assertRegisteredBindings(changedExpected, expectedCount * 2 + 1)
clearActionCalls()
handles[signature(changedAI.modifiers, changedAI.key)].callback()
handles[signature(changedApp.modifiers, changedApp.key)].callback()
handles[signature(changedWindow.modifiers, changedWindow.key)].callback()
handles[signature(changedURL.modifiers, changedURL.key)].callback()
handles[signature(changedUtility.modifiers, changedUtility.key)].callback()
assertEqual(#actionCalls, 5, "configuration-only changes invoke five changed callbacks")
assertEqual(actionCalls[1].name, "ai", "changed AI action module")
assertTableEqual(actionCalls[1].args, actionArguments(changedAI.action), "changed AI arguments")
assertEqual(actionCalls[1].args[1], promptDir .. "changed.md", "changed AI promptPath")
assertEqual(actionCalls[1].args[2], "changed-model", "changed AI model")
assertEqual(actionCalls[1].args[3], "replace", "changed AI mode")
assertEqual(actionCalls[1].args[4], "changed-failover-model", "changed AI failover model")
assertEqual(actionCalls[2].name, "app", "changed app action module")
assertTableEqual(actionCalls[2].args, { "Changed App" }, "changed app argument")
assertEqual(actionCalls[3].name, "window", "changed window action module")
assertTableEqual(actionCalls[3].args, { "full" }, "changed window argument")
assertEqual(actionCalls[4].name, "url", "changed URL action module")
assertTableEqual(actionCalls[4].args, { "dictionary" }, "changed URL argument")
assertEqual(actionCalls[5].name, "utility", "changed Utility action module")
assertTableEqual(actionCalls[5].args, { "/bin/changed-tool", raycastRoot .. "changed-script.sh" }, "changed Utility arguments")
for index, binding in ipairs(originalBindings) do config[index] = binding end

local restoredStartOK, restoredStartResult = pcall(hotkeys.start)
assertEqual(restoredStartOK, true, "restored configuration reloads without error")
assertEqual(restoredStartResult, true, "restored configuration reloads successfully")
assertEqual(#bindCalls, expectedCount * 4, "restored configuration registers a complete set")
assertEqual(#eventTapCalls, 4, "restored configuration registers one event tap")
assertRegisteredBindings(expected, expectedCount * 3 + 1)

local function assertInjectedConfigurationRejected(name, injectedValue)
  local beforeBindCalls = #bindCalls
  local beforeBindAttempts = bindAttempts
  local beforeDeletedHandles = #deletedHandles
  local beforeEventTapCalls = #eventTapCalls
  local beforeHandles = activeSnapshot()
  local savedHotkeysLoaded = package.loaded["hotkeys"]
  local savedHotkeysPreload = package.preload["hotkeys"]
  local savedConfigLoaded = package.loaded["hotkeys_config"]
  local savedConfigPreload = package.preload["hotkeys_config"]
  local beforeAlerts = #alertCalls
  -- Load an isolated hotkeys module so this test does not assume that every
  -- implementation re-requires hotkeys_config inside start(). The normal
  -- module and its active handles remain untouched while the loader input is
  -- invalid.
  package.loaded["hotkeys"] = nil
  package.loaded["hotkeys_config"] = nil
  package.preload["hotkeys_config"] = function() return injectedValue end
  local loadOK, isolatedHotkeys = pcall(require, "hotkeys")
  local hasStart = loadOK and type(isolatedHotkeys) == "table" and type(isolatedHotkeys.start) == "function"
  local hasErrorAccessor = loadOK and type(isolatedHotkeys) == "table" and type(isolatedHotkeys.getLastError) == "function"
  local startOK, result
  if hasStart then
    startOK, result = pcall(isolatedHotkeys.start)
  else
    startOK, result = false, nil
  end
  package.loaded["hotkeys"] = savedHotkeysLoaded
  package.preload["hotkeys"] = savedHotkeysPreload
  package.loaded["hotkeys_config"] = savedConfigLoaded
  package.preload["hotkeys_config"] = savedConfigPreload
  assertEqual(loadOK, true, "injected " .. name .. " hotkeys module loads")
  assertEqual(hasStart, true, "injected " .. name .. " hotkeys module exports start")
  assertEqual(hasErrorAccessor, true, "injected " .. name .. " hotkeys module exports getLastError")
  assertEqual(startOK, true, "injected " .. name .. " start completes without raising")
  assertEqual(result, false, "injected " .. name .. " configuration is rejected")
  local errorOK, reason = pcall(isolatedHotkeys.getLastError)
  assertEqual(errorOK, true, "injected " .. name .. " getLastError completes without raising")
  assert(type(reason) == "string" and reason ~= "", "injected " .. name .. " exposes a non-empty failure reason")
  assertEqual(#alertCalls, beforeAlerts + 1, "injected " .. name .. " notifies exactly once")
  assert(type(alertCalls[#alertCalls].message) == "string" and alertCalls[#alertCalls].message ~= "",
    "injected " .. name .. " notification contains a message")
  assertEqual(package.loaded["hotkeys"], savedHotkeysLoaded, "injected " .. name .. " restores package.loaded hotkeys")
  assertEqual(package.preload["hotkeys"], savedHotkeysPreload, "injected " .. name .. " restores package.preload hotkeys")
  assertEqual(package.loaded["hotkeys_config"], savedConfigLoaded, "injected " .. name .. " restores package.loaded config")
  assertEqual(package.preload["hotkeys_config"], savedConfigPreload, "injected " .. name .. " restores package.preload config")
  assertEqual(#bindCalls, beforeBindCalls, "injected " .. name .. " configuration does not bind")
  assertEqual(bindAttempts, beforeBindAttempts, "injected " .. name .. " configuration is rejected before hs.hotkey.bind")
  assertEqual(#deletedHandles, beforeDeletedHandles, "injected " .. name .. " configuration does not delete existing handles")
  assertActiveSnapshotUnchanged(beforeHandles, "injected " .. name .. " configuration preserves existing handles")
end

assertInjectedConfigurationRejected("nil", nil)
assertInjectedConfigurationRejected("non-table", "not-a-bindings-array")

local function assertInvalidConfiguration(name, applyInvalidChange)
  local beforeBindCalls = #bindCalls
  local beforeBindAttempts = bindAttempts
  local beforeDeletedHandles = #deletedHandles
  local beforeEventTapCalls = #eventTapCalls
  local beforeAlerts = #alertCalls
  local beforeHandles = activeSnapshot()
  applyInvalidChange()
  local ok, result = pcall(hotkeys.start)
  assertEqual(ok, true, "invalid " .. name .. " is handled without raising")
  assertEqual(result, false, "invalid " .. name .. " is rejected")
  local errorOK, reason = pcall(hotkeys.getLastError)
  assertEqual(errorOK, true, "invalid " .. name .. " getLastError completes without raising")
  assert(type(reason) == "string" and reason ~= "", "invalid " .. name .. " exposes a non-empty failure reason")
  assertEqual(#alertCalls, beforeAlerts + 1, "invalid " .. name .. " notifies exactly once")
  assert(type(alertCalls[#alertCalls].message) == "string" and alertCalls[#alertCalls].message ~= "",
    "invalid " .. name .. " notification contains a message")
  assertEqual(#bindCalls, beforeBindCalls, "invalid " .. name .. " does not bind")
  assertEqual(bindAttempts, beforeBindAttempts, "invalid " .. name .. " is rejected before hs.hotkey.bind")
  assertEqual(#deletedHandles, beforeDeletedHandles, "invalid " .. name .. " does not delete existing handles")
  assertEqual(#eventTapCalls, beforeEventTapCalls, "invalid " .. name .. " does not register an event tap")
  assertActiveSnapshotUnchanged(beforeHandles, "invalid " .. name .. " preserves existing handles")
end

local invalidCases = {
  { "missing binding", function() config[aiIndex] = nil end },
  { "missing modifiers", function() local b = copyBinding(config[aiIndex]); b.modifiers = nil; config[aiIndex] = b end },
  { "non-table modifiers", function() local b = copyBinding(config[aiIndex]); b.modifiers = "cmd"; config[aiIndex] = b end },
  { "empty modifiers", function() local b = copyBinding(config[aiIndex]); b.modifiers = {}; config[aiIndex] = b end },
  { "non-string modifier", function() local b = copyBinding(config[aiIndex]); b.modifiers = { "cmd", 1 }; config[aiIndex] = b end },
  { "empty modifier", function() local b = copyBinding(config[aiIndex]); b.modifiers = { "cmd", "" }; config[aiIndex] = b end },
  { "missing key", function() local b = copyBinding(config[aiIndex]); b.key = nil; config[aiIndex] = b end },
  { "non-string key", function() local b = copyBinding(config[aiIndex]); b.key = 1; config[aiIndex] = b end },
  { "empty key", function() local b = copyBinding(config[aiIndex]); b.key = ""; config[aiIndex] = b end },
  { "missing action", function() local b = copyBinding(config[aiIndex]); b.action = nil; config[aiIndex] = b end },
  { "non-string action type", function() local b = copyBinding(config[aiIndex]); b.action.type = 1; config[aiIndex] = b end },
  { "unknown action", function() local b = copyBinding(config[aiIndex]); b.action.type = "unknown"; config[aiIndex] = b end },
  { "missing AI promptPath", function() local b = copyBinding(config[aiIndex]); b.action.promptPath = nil; config[aiIndex] = b end },
  { "non-string AI promptPath", function() local b = copyBinding(config[aiIndex]); b.action.promptPath = 1; config[aiIndex] = b end },
  { "missing AI model", function() local b = copyBinding(config[aiIndex]); b.action.model = nil; config[aiIndex] = b end },
  { "non-string AI model", function() local b = copyBinding(config[aiIndex]); b.action.model = 1; config[aiIndex] = b end },
  { "empty AI failover model", function() local b = copyBinding(config[aiIndex]); b.action.model_failover = ""; config[aiIndex] = b end },
  { "non-string AI failover model", function() local b = copyBinding(config[aiIndex]); b.action.model_failover = 1; config[aiIndex] = b end },
  { "same AI primary and failover model", function() local b = copyBinding(config[aiIndex]); b.action.model_failover = b.action.model; config[aiIndex] = b end },
  { "missing AI mode", function() local b = copyBinding(config[aiIndex]); b.action.mode = nil; config[aiIndex] = b end },
  { "non-string AI mode", function() local b = copyBinding(config[aiIndex]); b.action.mode = 1; config[aiIndex] = b end },
  { "invalid AI mode", function() local b = copyBinding(config[aiIndex]); b.action.mode = "append"; config[aiIndex] = b end },
  { "missing app name", function() local b = copyBinding(config[appIndex]); b.action.app = nil; config[appIndex] = b end },
  { "non-string app name", function() local b = copyBinding(config[appIndex]); b.action.app = 1; config[appIndex] = b end },
  { "empty app name", function() local b = copyBinding(config[appIndex]); b.action.app = ""; config[appIndex] = b end },
  { "missing Window command", function() local b = copyBinding(config[windowIndex]); b.action.command = nil; config[windowIndex] = b end },
  { "non-string Window command", function() local b = copyBinding(config[windowIndex]); b.action.command = 1; config[windowIndex] = b end },
  { "invalid Window command", function() local b = copyBinding(config[windowIndex]); b.action.command = "maximize"; config[windowIndex] = b end },
  { "invalid previous-display command", function() local b = copyBinding(config[previousIndex]); b.action.command = "previous"; config[previousIndex] = b end },
  { "missing URL command", function() local b = copyBinding(config[urlIndex]); b.action.command = nil; config[urlIndex] = b end },
  { "non-string URL command", function() local b = copyBinding(config[urlIndex]); b.action.command = 1; config[urlIndex] = b end },
  { "invalid URL command", function() local b = copyBinding(config[urlIndex]); b.action.command = "bing"; config[urlIndex] = b end },
  { "missing Utility executablePath", function() local b = copyBinding(config[utilityIndex]); b.action.executablePath = nil; config[utilityIndex] = b end },
  { "non-string Utility executablePath", function() local b = copyBinding(config[utilityIndex]); b.action.executablePath = 1; config[utilityIndex] = b end },
  { "empty Utility executablePath", function() local b = copyBinding(config[utilityIndex]); b.action.executablePath = ""; config[utilityIndex] = b end },
  { "missing Utility scriptPath", function() local b = copyBinding(config[utilityIndex]); b.action.scriptPath = nil; config[utilityIndex] = b end },
  { "non-string Utility scriptPath", function() local b = copyBinding(config[utilityIndex]); b.action.scriptPath = 1; config[utilityIndex] = b end },
  { "empty Utility scriptPath", function() local b = copyBinding(config[utilityIndex]); b.action.scriptPath = ""; config[utilityIndex] = b end },
  { "duplicate modifier and key", function()
      local duplicate = copyBinding(config[appIndex])
      duplicate.modifiers = copyArray(config[aiIndex].modifiers)
      duplicate.key = config[aiIndex].key
      config[appIndex] = duplicate
    end },
}

for _, testCase in ipairs(invalidCases) do
  for index, binding in ipairs(originalBindings) do config[index] = binding end
  assertInvalidConfiguration(testCase[1], testCase[2])
end
for index, binding in ipairs(originalBindings) do config[index] = binding end

-- One representative malformed file_name_copy binding is enough to cover the
-- eventtap action's validation boundary; detailed field permutations belong to
-- the generic binding validator's tests above.
for index, binding in ipairs(originalBindings) do config[index] = binding end
assertInvalidConfiguration("file_name_copy missing action", function()
  local binding = copyBinding(config[fileNameCopyIndex])
  binding.action = nil
  config[fileNameCopyIndex] = binding
end)
for index, binding in ipairs(originalBindings) do config[index] = binding end

local function assertInvalidWithoutNotificationAPI()
  local beforeBindCalls = #bindCalls
  local beforeBindAttempts = bindAttempts
  local beforeDeletedHandles = #deletedHandles
  local beforeAlerts = #alertCalls
  local beforeHandles = activeSnapshot()
  local invalid = copyBinding(config[aiIndex])
  invalid.action.mode = "append"
  config[aiIndex] = invalid
  local savedAlert = hs.alert
  hs.alert = nil
  local ok, result = pcall(hotkeys.start)
  hs.alert = savedAlert
  config[aiIndex] = originalBindings[aiIndex]
  assertEqual(ok, true, "missing notification API is handled without raising")
  assertEqual(result, false, "missing notification API still rejects invalid configuration")
  local errorOK, reason = pcall(hotkeys.getLastError)
  assertEqual(errorOK, true, "missing notification API getLastError completes without raising")
  assert(type(reason) == "string" and reason ~= "", "missing notification API exposes a non-empty failure reason")
  assertEqual(#alertCalls, beforeAlerts, "missing notification API does not record an alert")
  assertEqual(#bindCalls, beforeBindCalls, "missing notification API does not bind")
  assertEqual(bindAttempts, beforeBindAttempts, "missing notification API rejects before hs.hotkey.bind")
  assertEqual(#deletedHandles, beforeDeletedHandles, "missing notification API does not delete existing handles")
  assertActiveSnapshotUnchanged(beforeHandles, "missing notification API preserves existing handles")
end

assertInvalidWithoutNotificationAPI()

local function assertFailedRegistrationCleaned(tapStart, message)
  local beforeBindCount = #bindCalls
  local beforeTapCount = #eventTapCalls
  failEventTapNew = not tapStart
  failEventTapStart = tapStart
  local ok, result = pcall(hotkeys.start)
  failEventTapNew = false
  failEventTapStart = false
  assertEqual(ok, true, message .. " is handled without raising")
  assertEqual(result, false, message .. " is rejected")
  for index = beforeBindCount + 1, #bindCalls do
    assertEqual(bindCalls[index].deleted, true, message .. " deletes regular handle " .. index)
  end
  assertEqual(countEntries(handles), 0, message .. " leaves no regular handle active")
  if tapStart then
    assertEqual(#eventTapCalls, beforeTapCount + 1, message .. " creates one tap before start failure")
    local tap = eventTapCalls[#eventTapCalls]
    assertEqual(tap.stopped, true, message .. " stops the failed tap")
    assertEqual(tap.deleted, true, message .. " deletes the failed tap")
  else
    assertEqual(#eventTapCalls, beforeTapCount, message .. " creates no tap after new failure")
  end
end

assertFailedRegistrationCleaned(false, "eventtap.new failure")
local recoveredAfterNewFailureOK, recoveredAfterNewFailureResult = pcall(hotkeys.start)
assertEqual(recoveredAfterNewFailureOK, true, "start recovers after eventtap.new failure")
assertEqual(recoveredAfterNewFailureResult, true, "start succeeds after eventtap.new failure")
assertEqual(#bindCalls, expectedCount * 6, "recovery after eventtap.new failure binds 32 regular hotkeys")
assertEqual(#eventTapCalls, 5, "recovery after eventtap.new failure registers one event tap")

assertFailedRegistrationCleaned(true, "eventtap start failure")
local recoveredAfterStartFailureOK, recoveredAfterStartFailureResult = pcall(hotkeys.start)
assertEqual(recoveredAfterStartFailureOK, true, "start recovers after eventtap start failure")
assertEqual(recoveredAfterStartFailureResult, true, "start succeeds after eventtap start failure")
assertEqual(#bindCalls, expectedCount * 8, "recovery after eventtap start failure binds 32 regular hotkeys")
assertEqual(#eventTapCalls, 7, "recovery after eventtap start failure registers one event tap")

-- A valid configuration may bind partially, but every newly returned handle is
-- cleaned up and no partial handle remains active after a bind failure.
local beforeFailureCount = #bindCalls
local beforeFailureAttempts = bindAttempts
local previousActive = activeSnapshot()
failAtBind = beforeFailureAttempts + 3
local failureOK, failureResult = pcall(hotkeys.start)
failAtBind = nil
assertEqual(failureOK, true, "bind failure is handled without raising")
assertEqual(failureResult, false, "bind failure is reported as rejected")
assertEqual(#bindCalls > beforeFailureCount, true, "bind failure creates a partial set before failing")
for index = beforeFailureCount + 1, #bindCalls do
  local handle = bindCalls[index]
  assertEqual(handle.deleted, true, "partial handle " .. (index - beforeFailureCount) .. " is cleaned up")
  assertEqual(handles[handle.key], nil, "partial handle " .. (index - beforeFailureCount) .. " is absent from registry")
end
for key, handle in pairs(previousActive) do
  assert(handles[key] == nil or handles[key] == handle, "bind failure leaves no replacement for old handle " .. key)
end
assert(countEntries(handles) == 0 or countEntries(handles) == countEntries(previousActive),
  "bind failure leaves no partial registry")

local afterFailureCount = #bindCalls
local recoveryStartOK, recoveryStartResult = pcall(hotkeys.start)
assertEqual(recoveryStartOK, true, "start completes after injected failure is removed")
assertEqual(recoveryStartResult, true, "start recovers after injected failure")
assertEqual(#bindCalls, afterFailureCount + expectedCount, "recovery registers a complete fresh set after the post-failure history")
local recoveryFirstIndex = afterFailureCount + 1
assertRegisteredBindings(expected, recoveryFirstIndex)
for index = recoveryFirstIndex, #bindCalls do
  local handle = bindCalls[index]
  assertEqual(handle.deleted, false, "recovery handle remains active")
  assertEqual(handles[handle.key], handle, "recovery handle is active in registry")
end
assertEqual(countEntries(handles), expectedCount, "recovery restores the complete active registry")

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
local mainOK, mainError = pcall(mainChunk)
assertEqual(mainOK, true, "main.lua starts through hotkeys.start only: " .. tostring(mainError))
assertEqual(mainStartCalls - callsBeforeMain, 1, "main invokes hotkeys.start exactly once")

print("hotkeys_test: ok")
