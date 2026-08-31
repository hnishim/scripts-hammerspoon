local M = {}
local hud = require("components.hud")
local resultPanel = require("components.result_panel")

local keychainService = "my.gemini-api.hammerspoon"
local keychainTimeout = 10
local httpTimeout = 65
local operationSequence = 0
local activeTask
local runCommand
local runPrompt

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function showMessage(message) hs.alert.show(message, 2) end
local function showSafeError() showMessage("Geminiコマンドを実行できませんでした。") end

local function stopTimer(timer)
  if timer and timer.stop then pcall(function() timer:stop() end) end
end

local function scheduleTimer(delay, callback)
  if not hs.timer or not hs.timer.doAfter then return false end
  local ok, timer = pcall(hs.timer.doAfter, delay, callback)
  if not ok or not timer then return false end
  return true, timer
end

local function readFile(path)
  local openOK, handle = pcall(io.open, path, "r")
  if not openOK or not handle then return false end
  local readOK, contents = pcall(handle.read, handle, "*a")
  pcall(handle.close, handle)
  if not readOK or contents == nil then return false end
  return true, contents
end

local function replacePromptPlaceholders(template, input)
  local function validate(prefix, pattern)
    local cursor = 1
    while true do
      local start = template:find(prefix, cursor, true)
      if not start then return true end
      local finish = template:find("}", start, true)
      if not finish then return false end
      if not template:sub(start, finish):match(pattern) then return false end
      cursor = finish + 1
    end
  end
  if not validate("{selection", "^{selection}$") then return false end
  if not validate("{argument", '^{argument name="[^"]+"}$') then return false end
  local rendered = template:gsub("{selection}", function() return input end)
  rendered = rendered:gsub('{argument name="[^"]+"}', function() return input end)
  return true, rendered
end

local function isActive(state)
  return state and not state.done and activeTask == state
end

local function release(state, errorMessage)
  if not state or state.done then return false end
  state.done = true
  stopTimer(state.watchdog)
  state.watchdog = nil
  if activeTask == state then activeTask = nil end
  hud.close()
  if errorMessage then showSafeError() end
  return true
end

local function createTask(path, callback, arguments)
  local ok, task = pcall(hs.task.new, path, callback, arguments)
  if not ok or not task then return nil end
  return task
end

local function startTask(task)
  local ok, result = pcall(task.start, task)
  return ok and result ~= false
end

function M.stop()
  operationSequence = operationSequence + 1
  local state = activeTask
  activeTask = nil
  if state then
    state.done = true
    stopTimer(state.watchdog)
    state.watchdog = nil
    if state.keyTask and state.keyTask.terminate then pcall(state.keyTask.terminate, state.keyTask) end
    state.keyTask = nil
  end
  pcall(hud.close)
  pcall(resultPanel.stop)
end

local function acquireSelection()
  if not hs.uielement or not hs.uielement.focusedElement then return nil, false end
  local focusedOK, focused = pcall(hs.uielement.focusedElement)
  if not focusedOK or not focused then return nil, false end
  local selectedOK, selection = pcall(function() return focused:selectedText() end)
  if not selectedOK or selection == nil then return nil, false end
  return selection, true
end

local function frontmost(target)
  if not target or type(target.isFrontmost) ~= "function" then return false end
  local ok, value = pcall(function() return target:isFrontmost() end)
  return ok and value == true
end

local function bundleID(target)
  if not target or type(target.bundleID) ~= "function" then return false end
  local ok, value = pcall(function() return target:bundleID() end)
  return ok and value or false
end

local function isPowerPoint(target)
  local id = bundleID(target)
  return id == "com.microsoft.Powerpoint" or id == "com.microsoft.PowerPoint"
end

local function clipboardContents()
  return pcall(hs.pasteboard.getContents)
end

local function changeCount()
  local ok, value = pcall(hs.pasteboard.changeCount)
  return ok and value ~= nil, value
end

local function setContents(value)
  local ok, result = pcall(hs.pasteboard.setContents, value)
  return ok and result ~= false
end

local function clearContents()
  local ok, result = pcall(hs.pasteboard.clearContents)
  return ok and result ~= false
end

local function activate(target)
  local ok, result = pcall(function() return target:activate() end)
  return ok and result ~= false
end

local function clipboardSnapshot()
  if not hs.pasteboard or type(hs.pasteboard.allContentTypes) ~= "function" then return false end
  local beforeOK, before = changeCount()
  if not beforeOK then return false end
  local typesOK, types = pcall(hs.pasteboard.allContentTypes)
  if not typesOK or type(types) ~= "table" then return false end
  local afterOK, after = changeCount()
  if not afterOK or before ~= after then return false end
  if #types == 0 then return true, { kind = "empty" }, after, types end
  if #types ~= 1 or type(hs.pasteboard.readAllData) ~= "function" then return false end
  local dataOK, data = pcall(hs.pasteboard.readAllData)
  if not dataOK or type(data) ~= "table" then return false end
  return true, { kind = "data", data = data }, after, types
end

local function restoreClipboard(snapshot)
  if not snapshot then return false end
  if snapshot.kind == "empty" then return clearContents() end
  if snapshot.kind == "data" and type(hs.pasteboard.writeAllData) == "function" then
    local ok, result = pcall(hs.pasteboard.writeAllData, snapshot.data)
    return ok and result ~= false
  end
  return false
end

local function clipboardIsText(types)
  if type(types) ~= "table" or #types ~= 1 or type(types[1]) ~= "table" then return false end
  for _, uti in ipairs(types[1]) do
    if uti == "public.utf8-plain-text" or uti == "public.utf16-external-plain-text"
        or uti == "public.rtf" or uti == "com.apple.rtfd" or uti == "com.apple.flat-rtfd" then
      return true
    end
  end
  return false
end

local function clipboardMatches(expectedContents, expectedCount)
  local snapshotOK, _, currentCount, types = clipboardSnapshot()
  if not snapshotOK or currentCount ~= expectedCount then return false end
  if not clipboardIsText(types) then return false end
  local contentsOK, contents = clipboardContents()
  return contentsOK and contents == expectedContents
end

local function finishReplace(target, response, complete, priorSnapshot)
  local function done(errorMessage)
    complete(errorMessage)
  end
  local function restoreIfUntouched(prior, postCount, reportError)
    if not clipboardMatches(response, postCount) then done("error"); return end
    local restored = restoreClipboard(prior)
    if restored then done(reportError and "error" or nil) else done("error") end
  end
  local function scheduleRestore(prior, postCount, reportError)
    if not hs.timer or not hs.timer.doAfter then done("error"); return end
    local ok = pcall(hs.timer.doAfter, 0.2, function() restoreIfUntouched(prior, postCount, reportError) end)
    if not ok then done("error") end
  end
  local function scheduleError()
    if not hs.timer or not hs.timer.doAfter then done("error"); return end
    local ok = pcall(hs.timer.doAfter, 0.2, function() done("error") end)
    if not ok then done("error") end
  end

  if not target then scheduleError(); return end

  if not target or not activate(target) or not frontmost(target) then scheduleError(); return end
  local prior, beforeCount
  if priorSnapshot then
    prior = priorSnapshot.snapshot
    beforeCount = priorSnapshot.currentCount or priorSnapshot.count
    if priorSnapshot.currentCount and not clipboardMatches(priorSnapshot.currentContents, beforeCount) then
      scheduleError(); return
    end
    if not priorSnapshot.currentCount then
      local currentCountOK, currentCount = changeCount()
      if not currentCountOK or currentCount ~= beforeCount then scheduleError(); return end
    end
  else
    local priorOK
    priorOK, prior, beforeCount = clipboardSnapshot()
    if not priorOK then scheduleError(); return end
  end
  if not setContents(response) then scheduleError(); return end
  local responseOK, _, postCount = clipboardSnapshot()
  if not responseOK or postCount ~= beforeCount + 1 then scheduleError(); return end
  local responseContentsOK, responseContents = clipboardContents()
  if not responseContentsOK or responseContents ~= response then scheduleError(); return end
  if not frontmost(target) then scheduleError(); return end
  if not clipboardMatches(response, postCount) then scheduleError(); return end
  local pasteOK, pasteResult = pcall(hs.eventtap.keyStroke, { "cmd" }, "v")
  if not pasteOK or pasteResult == false then scheduleRestore(prior, postCount, true); return end
  scheduleRestore(prior, postCount)
end

local function responseText(payload)
  if type(payload) ~= "table" then return false end
  local feedback = payload.promptFeedback
  if feedback ~= nil and type(feedback) ~= "table" then return false end
  if feedback and feedback.blockReason then return false end
  local candidates = payload.candidates
  if type(candidates) ~= "table" or #candidates == 0 then return false end
  local candidate = candidates[1]
  if type(candidate) ~= "table" then return false end
  if candidate.finishReason == "SAFETY" then return false end
  local content = candidate.content
  if type(content) ~= "table" then return false end
  local parts = content.parts
  if type(parts) ~= "table" then return false end
  local text = {}
  for index = 1, #parts do
    local part = parts[index]
    if type(part) ~= "table" then return false end
    if part.text ~= nil and type(part.text) ~= "string" then return false end
    if part.text ~= nil then text[#text + 1] = part.text end
  end
  local result = table.concat(text)
  if result == "" then return false end
  return true, trim(result)
end

local function startGemini(state, command, prompt, apiKey, target)
  if not isActive(state) or not hs.http or not hs.http.asyncPost or not hs.json or not hs.json.encode then
    release(state, true)
    return
  end
  local encodeOK, body = pcall(hs.json.encode, {
    contents = { { parts = { { text = prompt } } } },
  })
  if not encodeOK or not body then release(state, true); return end
  local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. command.model .. ":generateContent"
  local headers = { ["Content-Type"] = "application/json", ["x-goog-api-key"] = apiKey }
  local function callback(status, responseBody, _)
    if not isActive(state) then return end
    stopTimer(state.watchdog)
    state.watchdog = nil
    if type(status) ~= "number" or status < 200 or status >= 300 or type(responseBody) ~= "string" then
      release(state, true)
      return
    end
    local decodeOK, payload = pcall(hs.json.decode, responseBody)
    if not decodeOK then release(state, true); return end
    local responseOK, response = responseText(payload)
    if not responseOK or response == "" then release(state, true); return end
    if target then
      finishReplace(target, response, function(errorMessage) release(state, errorMessage) end, state.priorSnapshot)
      return
    end
    release(state)
    local showOK, displayed = pcall(resultPanel.show, response)
    if not showOK or not displayed then showSafeError() end
  end
  local timerOK, timer = scheduleTimer(httpTimeout, function()
    if not isActive(state) then return end
    state.httpTimedOut = true
    release(state, true)
  end)
  if not timerOK then release(state, true); return end
  state.watchdog = timer
  local postOK = pcall(hs.http.asyncPost, url, body, headers, callback)
  if not postOK and isActive(state) then release(state, true) end
end

local function startKeychain(state, command, prompt, target)
  if not isActive(state) then return end
  local function fail()
    release(state, true)
  end
  local function armWatchdog()
    stopTimer(state.watchdog)
    local timerOK, timer = scheduleTimer(keychainTimeout, function()
      if not isActive(state) then return end
      if state.keyTask and state.keyTask.terminate then pcall(state.keyTask.terminate, state.keyTask) end
      release(state, true)
    end)
    if not timerOK then fail(); return false end
    state.watchdog = timer
    return true
  end
  local function securityCallback(exitCode, stdout, _)
    if not isActive(state) then return end
    stopTimer(state.watchdog)
    state.watchdog = nil
    state.keyTask = nil
    if exitCode ~= 0 then fail(); return end
    local apiKey = trim(stdout)
    if apiKey == "" then fail(); return end
    startGemini(state, command, prompt, apiKey, target)
  end
  local function accountCallback(exitCode, stdout, _)
    if not isActive(state) then return end
    stopTimer(state.watchdog)
    state.watchdog = nil
    state.keyTask = nil
    if exitCode ~= 0 then fail(); return end
    local account = trim(stdout)
    if account == "" then fail(); return end
    local security = createTask("/usr/bin/security", securityCallback, {
      "find-generic-password", "-s", keychainService, "-a", account, "-w",
    })
    if not security then fail(); return end
    state.keyTask = security
    if not startTask(security) then state.keyTask = nil; fail(); return end
    armWatchdog()
  end
  local account = createTask("/usr/bin/id", accountCallback, { "-un" })
  if not account then fail(); return end
  state.keyTask = account
  if not startTask(account) then state.keyTask = nil; fail(); return end
  armWatchdog()
end

local function runPowerPointFallback(promptPath, model, mode, target)
  if not frontmost(target) then showSafeError(); return false end
  local priorOK, prior, beforeCount = clipboardSnapshot()
  if not priorOK then showSafeError(); return false end
  local copyOK, copyResult = pcall(hs.eventtap.keyStroke, { "cmd" }, "c")
  if not copyOK or copyResult == false then showSafeError(); return false end
  local timerOK = scheduleTimer(0.1, function()
    if not isPowerPoint(target) or not frontmost(target) then showSafeError(); return end
    local currentOK, current, currentCount, types = clipboardSnapshot()
    if not currentOK then showSafeError(); return end
    if currentCount == beforeCount then
      runPrompt(promptPath, model)
      return
    end
    if currentCount ~= beforeCount + 1 or not clipboardIsText(types) then showSafeError(); return end
    local contentsOK, contents = clipboardContents()
    if not contentsOK or type(contents) ~= "string" then showSafeError(); return end
    if contents == "" then
      if not restoreClipboard(prior) then showSafeError(); return end
      runPrompt(promptPath, model)
      return
    end
    if mode ~= "replace" then
      if not restoreClipboard(prior) then showSafeError(); return end
    end
    local priorSnapshot = { snapshot = prior, count = beforeCount,
      currentCount = currentCount, currentContents = contents }
    runCommand(promptPath, model, mode, contents, mode == "replace" and target or nil,
      mode == "replace" and priorSnapshot or nil)
  end)
  if not timerOK then showSafeError(); return false end
  return true
end

runPrompt = function(promptPath, model)
  local button, input = hs.dialog.textPrompt("Gemini AI command", "Geminiへ渡すテキストを入力してください。", "", "実行", "キャンセル")
  if button ~= "実行" then return end
  input = trim(input)
  if input == "" then showMessage("入力テキストが空です。"); return end
  runCommand(promptPath, model, "display", input, nil)
end

runCommand = function(promptPath, model, mode, input, target, priorSnapshot)
  if activeTask then showMessage("別のAIコマンドを実行中です。"); return end
  if type(promptPath) ~= "string" or promptPath == "" or type(model) ~= "string" or model == ""
      or (mode ~= "display" and mode ~= "replace") or type(input) ~= "string" then
    showSafeError(); return false
  end
  local promptOK, template = readFile(promptPath)
  if not promptOK then showSafeError(); return end
  local renderedOK, prompt = replacePromptPlaceholders(template, input)
  if not renderedOK then showSafeError(); return end
  prompt = prompt:gsub("%s+$", "")
  operationSequence = operationSequence + 1
  local state = { token = operationSequence, done = false, keyTask = nil, watchdog = nil,
    priorSnapshot = priorSnapshot }
  activeTask = state
  hud.show("Gemini処理中...")
  startKeychain(state, { model = model }, prompt, target)
  return true
end

function M.run(promptPath, model, mode)
  if type(promptPath) ~= "string" or promptPath == "" or type(model) ~= "string" or model == ""
      or (mode ~= "display" and mode ~= "replace") then
    showSafeError(); return false
  end
  local target
  local appOK, app = pcall(hs.application.frontmostApplication)
  if appOK then target = app end
  if mode == "replace" and not target then showSafeError(); return false end
  local powerPoint = isPowerPoint(target)
  local selection, acquired = acquireSelection()
  if not acquired then
    if powerPoint then return runPowerPointFallback(promptPath, model, mode, target) end
    showSafeError()
    return false
  end
  if selection == "" then
    runPrompt(promptPath, model)
    return true
  end
  local priorSnapshot
  if mode == "replace" then
    local priorOK, snapshot, count = clipboardSnapshot()
    if not priorOK then showSafeError(); return false end
    priorSnapshot = { snapshot = snapshot, count = count }
  end
  return runCommand(promptPath, model, mode, selection, mode == "replace" and target or nil, priorSnapshot)
end

return M
