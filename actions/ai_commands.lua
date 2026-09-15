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
local handleReplacementResponse

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

local function terminateTask(task)
  if task and task.terminate then pcall(task.terminate, task) end
end

local function release(state, errorMessage)
  if not state or state.done then return false end
  state.done = true
  stopTimer(state.watchdog)
  state.watchdog = nil
  terminateTask(state.keyTask)
  state.keyTask = nil
  terminateTask(state.helperTask)
  state.helperTask = nil
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

local function createStreamingTask(path, callback, streamCallback, arguments)
  local ok, task = pcall(hs.task.new, path, callback, streamCallback, arguments)
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
    terminateTask(state.keyTask)
    state.keyTask = nil
    terminateTask(state.helperTask)
    state.helperTask = nil
  end
  pcall(hud.close)
  pcall(resultPanel.stop)
end

local function focusedElement()
  if not hs.uielement or not hs.uielement.focusedElement then return nil, false end
  local focusedOK, focused = pcall(hs.uielement.focusedElement)
  return focused, focusedOK and focused ~= nil
end

local function acquireSelection()
  local focused, focusedOK = focusedElement()
  if not focusedOK then return nil, false end
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

local function clearContents()
  local ok, result = pcall(hs.pasteboard.clearContents)
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

local function clipboardContentsMatch(expectedContents, expectedCount)
  local snapshotOK, _, currentCount = clipboardSnapshot()
  if not snapshotOK or currentCount ~= expectedCount then return false end
  local contentsOK, contents = clipboardContents()
  return contentsOK and contents == expectedContents
end

local function responseText(payload)
  if type(payload) ~= "table" then return false end
  local feedback = payload.promptFeedback
  if feedback ~= nil and type(feedback) ~= "table" then return false end
  if feedback and feedback.blockReason then return false end
  local candidates = payload.candidates
  if type(candidates) ~= "table" or #candidates == 0 then return false end
  local candidate = candidates[1]
  if type(candidate) ~= "table" or candidate.finishReason == "SAFETY" then return false end
  local content = candidate.content
  if type(content) ~= "table" or type(content.parts) ~= "table" then return false end
  local text = {}
  for index = 1, #content.parts do
    local part = content.parts[index]
    if type(part) ~= "table" then return false end
    if part.text ~= nil and type(part.text) ~= "string" then return false end
    if part.text ~= nil then text[#text + 1] = part.text end
  end
  local result = table.concat(text)
  if result == "" then return false end
  return true, trim(result)
end

local function showResult(response)
  local showOK, displayed = pcall(resultPanel.show, response)
  if not showOK or not displayed then showSafeError() end
end

local function startGemini(state, command, prompt, apiKey)
  if not isActive(state) or not hs.http or not hs.http.asyncPost or not hs.json or not hs.json.encode then
    release(state, true)
    return
  end
  local encodeOK, body = pcall(hs.json.encode, {
    contents = { { parts = { { text = prompt } } } },
  })
  if not encodeOK or not body then release(state, true); return end
  local headers = { ["Content-Type"] = "application/json", ["x-goog-api-key"] = apiKey }
  local function issue(model, isFallback)
    if not isActive(state) then return end
    state.requestGeneration = (state.requestGeneration or 0) + 1
    local generation = state.requestGeneration
    local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent"
    local function failRequest()
      if not isActive(state) or state.requestGeneration ~= generation then return end
      stopTimer(state.watchdog)
      state.watchdog = nil
      if not isFallback and command.model_failover then
        issue(command.model_failover, true)
      else
        release(state, true)
      end
    end
    local function failLocal()
      if not isActive(state) or state.requestGeneration ~= generation then return end
      stopTimer(state.watchdog)
      state.watchdog = nil
      release(state, true)
    end
    local function callback(status, responseBody, _)
      if not isActive(state) or state.requestGeneration ~= generation then return end
      stopTimer(state.watchdog)
      state.watchdog = nil
      if type(status) ~= "number" or status < 200 or status >= 300 or type(responseBody) ~= "string" then
        failRequest(); return
      end
      local decodeOK, payload = pcall(hs.json.decode, responseBody)
      if not decodeOK then failRequest(); return end
      local responseOK, response = responseText(payload)
      if not responseOK or response == "" then failRequest(); return end
      if state.replacementSession then
        handleReplacementResponse(state, response)
        return
      end
      release(state)
      showResult(response)
    end
    local timerOK, timer = scheduleTimer(httpTimeout, function()
      if not isActive(state) or state.requestGeneration ~= generation then return end
      failRequest()
    end)
    if not timerOK then failLocal(); return end
    state.watchdog = timer
    local postOK = pcall(hs.http.asyncPost, url, body, headers, callback)
    if not postOK then failLocal() end
  end
  issue(command.model, false)
end

local function startKeychain(state, command, prompt)
  if not isActive(state) then return end
  local function fail() release(state, true) end
  local function armWatchdog()
    stopTimer(state.watchdog)
    local timerOK, timer = scheduleTimer(keychainTimeout, function()
      if not isActive(state) then return end
      terminateTask(state.keyTask)
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
    startGemini(state, command, prompt, apiKey)
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

local function runPowerPointFallback(promptPath, model, target, modelFailover)
  if not frontmost(target) then showSafeError(); return false end
  local priorOK, prior, beforeCount = clipboardSnapshot()
  if not priorOK then showSafeError(); return false end
  local copyOK, copyResult = pcall(hs.eventtap.keyStroke, { "cmd" }, "c")
  if not copyOK or copyResult == false then showSafeError(); return false end
  local timerOK = scheduleTimer(0.1, function()
    if not isPowerPoint(target) or not frontmost(target) then showSafeError(); return end
    local currentOK, _, currentCount, types = clipboardSnapshot()
    if not currentOK then showSafeError(); return end
    if currentCount == beforeCount then runPrompt(promptPath, model, modelFailover); return end
    if currentCount ~= beforeCount + 1 or not clipboardIsText(types) then showSafeError(); return end
    local contentsOK, contents = clipboardContents()
    if not contentsOK or type(contents) ~= "string" then showSafeError(); return end
    if not restoreClipboard(prior) then showSafeError(); return end
    if contents == "" then runPrompt(promptPath, model, modelFailover); return end
    runCommand(promptPath, model, contents, modelFailover)
  end)
  if not timerOK then showSafeError(); return false end
  return true
end

local function runClipboardFallback(promptPath, model, modelFailover, target)
  if not frontmost(target) then showSafeError(); return false end
  local priorOK, prior, beforeCount = clipboardSnapshot()
  if not priorOK then showSafeError(); return false end
  local copyOK, copyResult = pcall(hs.eventtap.keyStroke, { "cmd" }, "c")
  if not copyOK or copyResult == false then showSafeError(); return false end
  local timerOK = scheduleTimer(0.1, function()
    if not frontmost(target) then showSafeError(); return end
    local currentOK, _, currentCount, types = clipboardSnapshot()
    if not currentOK or currentCount ~= beforeCount + 1 then showSafeError(); return end
    local contentsOK, contents = clipboardContents()
    if not contentsOK or type(contents) ~= "string" then showSafeError(); return end
    if not clipboardContentsMatch(contents, currentCount) then showSafeError(); return end
    if not clipboardIsText(types) then
      if not restoreClipboard(prior) then showSafeError(); return end
      showSafeError(); return
    end
    if not restoreClipboard(prior) then showSafeError(); return end
    if contents == "" then runPrompt(promptPath, model, modelFailover); return end
    runCommand(promptPath, model, contents, modelFailover)
  end)
  if not timerOK then showSafeError(); return false end
  return true
end

runPrompt = function(promptPath, model, modelFailover)
  local button, input = hs.dialog.textPrompt("Gemini AI command", "Geminiへ渡すテキストを入力してください。", "", "実行", "キャンセル")
  if button ~= "実行" then return end
  input = trim(input)
  if input == "" then showMessage("入力テキストが空です。"); return end
  runCommand(promptPath, model, input, modelFailover)
end

runCommand = function(promptPath, model, input, modelFailover)
  if activeTask then showMessage("別のAIコマンドを実行中です。"); return end
  if type(promptPath) ~= "string" or promptPath == "" or type(model) ~= "string" or model == ""
      or type(input) ~= "string" then
    showSafeError(); return false
  end
  local promptOK, template = readFile(promptPath)
  if not promptOK then showSafeError(); return end
  local renderedOK, prompt = replacePromptPlaceholders(template, input)
  if not renderedOK then showSafeError(); return end
  prompt = prompt:gsub("%s+$", "")
  operationSequence = operationSequence + 1
  local state = { token = operationSequence, done = false, keyTask = nil, helperTask = nil, watchdog = nil }
  activeTask = state
  hud.show("Gemini処理中...")
  startKeychain(state, { model = model, model_failover = modelFailover }, prompt)
  return true
end

local function replacementHelperPath()
  local source = debug and debug.getinfo and debug.getinfo(1, "S")
  source = source and source.source or ""
  if source:sub(1, 1) == "@" then source = source:sub(2) end
  local root = source:match("^(.*)/actions/ai_commands%.lua$")
  if not root or root == "" then root = "." end
  return root .. "/helpers/replacement-engine/.build/release/replacement-engine"
end

local function protocolFailure(state)
  release(state, true)
end

local function processHelperEvent(state, event)
  if not isActive(state) or type(event) ~= "table" or type(event.event) ~= "string" then
    protocolFailure(state); return
  end

  if event.event == "capture" then
    if state.captureReceived or type(event.selection) ~= "string" or event.selection == ""
        or type(event.replacement_eligible) ~= "boolean" or type(event.reason) ~= "string" then
      protocolFailure(state); return
    end
    state.captureReceived = true
    state.replacementEligible = event.replacement_eligible
    stopTimer(state.watchdog)
    state.watchdog = nil
    local renderedOK, prompt = replacePromptPlaceholders(state.promptTemplate, event.selection)
    if not renderedOK then protocolFailure(state); return end
    prompt = prompt:gsub("%s+$", "")
    startKeychain(state, state.command, prompt)
    return
  end

  if event.event == "outcome" then
    if not state.captureReceived or not state.waitingOutcome or type(event.outcome) ~= "string" then
      protocolFailure(state); return
    end
    local outcome = event.outcome
    if outcome == "verified_replaced" or outcome == "replacement_dispatched_unverified" then
      release(state)
      return
    end
    if outcome == "not_replaced" then
      local response = state.pendingResponse
      release(state)
      if response then showResult(response) else showSafeError() end
      return
    end
    if outcome == "error" then
      release(state, true)
      return
    end
    protocolFailure(state)
    return
  end

  protocolFailure(state)
end

local function consumeHelperOutput(state, stdout)
  if not isActive(state) or type(stdout) ~= "string" or stdout == "" then return end
  state.helperBuffer = (state.helperBuffer or "") .. stdout
  while isActive(state) do
    local newline = state.helperBuffer:find("\n", 1, true)
    if not newline then return end
    local line = state.helperBuffer:sub(1, newline - 1)
    state.helperBuffer = state.helperBuffer:sub(newline + 1)
    if line ~= "" then
      local ok, event = pcall(hs.json.decode, line)
      if not ok or type(event) ~= "table" then protocolFailure(state); return end
      processHelperEvent(state, event)
    end
  end
end

handleReplacementResponse = function(state, response)
  if not isActive(state) then return end
  if not state.replacementEligible then
    release(state)
    showResult(response)
    return
  end
  local helper = state.helperTask
  if not helper or type(helper.setInput) ~= "function" then release(state, true); return end
  local encodeOK, encoded = pcall(hs.json.encode, { replacement = response })
  if not encodeOK or type(encoded) ~= "string" then release(state, true); return end

  state.pendingResponse = response
  state.waitingOutcome = true
  local timerOK, timer = scheduleTimer(keychainTimeout, function()
    if isActive(state) and state.waitingOutcome then release(state, true) end
  end)
  if not timerOK then release(state, true); return end
  state.watchdog = timer

  local inputOK, inputResult = pcall(helper.setInput, helper, encoded .. "\n")
  if not inputOK or inputResult == false then release(state, true); return end
end

local function startReplacementSession(promptPath, model, modelFailover)
  if activeTask then
    if activeTask.replacementSession then M.stop() else showMessage("別のAIコマンドを実行中です。"); return false end
  end
  local promptOK, template = readFile(promptPath)
  if not promptOK then showSafeError(); return false end

  operationSequence = operationSequence + 1
  local state = {
    token = operationSequence,
    done = false,
    replacementSession = true,
    captureReceived = false,
    replacementEligible = false,
    waitingOutcome = false,
    helperBuffer = "",
    helperTask = nil,
    keyTask = nil,
    watchdog = nil,
    promptTemplate = template,
    command = { model = model, model_failover = modelFailover },
  }
  activeTask = state
  hud.show("Gemini処理中...")

  local function helperCallback(exitCode, stdout, _)
    if not isActive(state) then return end
    if type(stdout) == "string" and stdout ~= "" then consumeHelperOutput(state, stdout) end
    if not isActive(state) then return end
    if exitCode ~= 0 or not state.captureReceived or state.waitingOutcome then
      release(state, true)
      return
    end
    release(state, true)
  end

  local function streamCallback(_, stdout, _)
    consumeHelperOutput(state, stdout)
    return isActive(state)
  end

  local helper = createStreamingTask(replacementHelperPath(), helperCallback, streamCallback, {})
  if not helper then release(state, true); return false end
  state.helperTask = helper
  if not startTask(helper) then release(state, true); return false end

  local timerOK, timer = scheduleTimer(keychainTimeout, function()
    if isActive(state) and not state.captureReceived then release(state, true) end
  end)
  if not timerOK then release(state, true); return false end
  state.watchdog = timer
  return true
end

function M.run(promptPath, model, mode, modelFailover)
  if type(promptPath) ~= "string" or promptPath == "" or type(model) ~= "string" or model == ""
      or (mode ~= "display" and mode ~= "replace")
      or (modelFailover ~= nil and (type(modelFailover) ~= "string" or modelFailover == "" or modelFailover == model)) then
    showSafeError(); return false
  end

  if mode == "replace" then
    return startReplacementSession(promptPath, model, modelFailover)
  end

  if activeTask and activeTask.replacementSession then M.stop() end
  local target
  local appOK, app = pcall(hs.application.frontmostApplication)
  if appOK then target = app end
  local powerPoint = isPowerPoint(target)
  local selection, acquired = acquireSelection()
  if not acquired then
    if powerPoint then return runPowerPointFallback(promptPath, model, target, modelFailover) end
    return runClipboardFallback(promptPath, model, modelFailover, target)
  end
  if selection == "" then
    runPrompt(promptPath, model, modelFailover)
    return true
  end
  return runCommand(promptPath, model, selection, modelFailover)
end

return M
