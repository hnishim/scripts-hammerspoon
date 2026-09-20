local M = {}
local hud = require("components.hud")
local resultPanel = require("components.result_panel")
local textIO = require("components.text_io")
local textPrompt = require("components.text_prompt")

local keychainService = "my.gemini-api.hammerspoon"
local keychainTimeout = 10
local httpTimeout = 65
local operationSequence = 0
local activeTask
local pendingInput

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function showMessage(message) hs.alert.show(message, 2) end
local function showSafeError() showMessage("Could not run the Gemini command.") end

local function showTransientMessage(message)
  if type(hud) == "table" and type(hud.showTransient) == "function" then
    local ok, shown = pcall(hud.showTransient, message, 2)
    if ok and shown ~= nil and shown ~= false then return true end
  end
  showMessage(message)
  return false
end

local function stopTimer(timer)
  if timer and timer.stop then pcall(timer.stop, timer) end
end

local function scheduleTimer(delay, callback)
  if not hs.timer or not hs.timer.doAfter then return false end
  local ok, timer = pcall(hs.timer.doAfter, delay, callback)
  if not ok or not timer then return false end
  return true, timer
end

local function terminateTask(task)
  if task and task.terminate then pcall(task.terminate, task) end
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
  terminateTask(state.keyTask)
  state.keyTask = nil
  if activeTask == state then activeTask = nil end
  if state.hudShown then pcall(hud.close) end
  if errorMessage then showSafeError() end
  return true
end

local function showResult(response)
  local showOK, displayed = pcall(resultPanel.show, response)
  if not showOK or not displayed then showSafeError() end
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
  local result = trim(table.concat(text))
  if result == "" then return false end
  return true, result
end

local function handleResponse(state, response)
  if not isActive(state) then return end
  if not state.replaceHandle then
    release(state)
    showResult(response)
    return
  end

  local callbackCalled = false
  local function outcomeCallback(result)
    callbackCalled = true
    if not isActive(state) then return end
    if type(result) ~= "table" or type(result.outcome) ~= "string" then
      release(state, true)
      return
    end
    if result.outcome == "verified_replaced" or result.outcome == "replacement_dispatched_unverified" then
      release(state)
      return
    end
    if result.outcome == "not_replaced" then
      release(state)
      showResult(response)
      return
    end
    release(state, true)
  end

  local ok, started = pcall(state.replaceHandle, response, outcomeCallback)
  if not ok then
    if isActive(state) then release(state, true) end
    return
  end
  if started == false and not callbackCalled and isActive(state) then release(state, true) end
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
      if not isFallback and command.model_failover then issue(command.model_failover, true)
      else release(state, true) end
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
      if not responseOK then failRequest(); return end
      handleResponse(state, response)
    end

    local timerOK, timer = scheduleTimer(httpTimeout, function()
      if isActive(state) and state.requestGeneration == generation then failRequest() end
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

local function beginOperation(promptPath, model, modelFailover, input, replaceHandle, replacementSession)
  local promptOK, template = readFile(promptPath)
  if not promptOK then showSafeError(); return false end
  local renderedOK, prompt = replacePromptPlaceholders(template, input)
  if not renderedOK then showSafeError(); return false end
  prompt = prompt:gsub("%s+$", "")

  operationSequence = operationSequence + 1
  local state = {
    token = operationSequence,
    done = false,
    keyTask = nil,
    watchdog = nil,
    hudShown = true,
    replacementSession = replacementSession == true,
    replaceHandle = replaceHandle,
  }
  activeTask = state
  hud.show("Processing...")
  startKeychain(state, { model = model, model_failover = modelFailover }, prompt)
  return true
end

local function promptDisplay(promptPath, model, modelFailover)
  local entry = { done = false }
  pendingInput = entry
  local function complete(result)
    if pendingInput ~= entry or entry.done then return end
    entry.done = true
    pendingInput = nil
    if type(result) ~= "table" then showSafeError(); return end
    if result.status == "submitted" then
      beginOperation(promptPath, model, modelFailover, result.text)
    elseif result.status == "empty" then
      showTransientMessage("Input is empty.")
    elseif result.status ~= "cancelled" then
      showSafeError()
    end
  end
  local ok, started = pcall(textPrompt.request, {
    title = "Gemini AI command",
    message = "Enter text for Gemini.",
    submit = "Run",
    cancel = "Cancel",
  }, complete)
  if not ok or started == false then
    if pendingInput == entry then complete({ status = "error" }) end
    return false
  end
  return true
end

function M.stop()
  operationSequence = operationSequence + 1
  local state = activeTask
  activeTask = nil
  local waiting = pendingInput
  pendingInput = nil
  if waiting then
    waiting.done = true
    pcall(textPrompt.close)
  end
  if state and not state.done then
    state.done = true
    stopTimer(state.watchdog)
    terminateTask(state.keyTask)
    state.watchdog = nil
    state.keyTask = nil
  end
  pcall(textIO.stop)
  pcall(hud.close)
  pcall(resultPanel.stop)
  return true
end

function M.run(promptPath, model, mode, modelFailover)
  if type(promptPath) ~= "string" or promptPath == "" or type(model) ~= "string" or model == ""
      or (mode ~= "display" and mode ~= "replace")
      or (modelFailover ~= nil and (type(modelFailover) ~= "string" or modelFailover == "" or modelFailover == model)) then
    showSafeError(); return false
  end

  if pendingInput then showMessage("Another AI command is running."); return false end
  if activeTask then
    if activeTask.replacementSession then M.stop()
    else showMessage("Another AI command is running."); return false end
  end

  if mode == "display" then
    local started = textIO.capture("read", function(result)
      if type(result) ~= "table" then showSafeError(); return end
      if result.status == "selected" then
        beginOperation(promptPath, model, modelFailover, result.text)
      elseif result.status == "none" then
        promptDisplay(promptPath, model, modelFailover)
      else
        showSafeError()
      end
    end)
    return started ~= false
  end

  local started = textIO.capture("replace", function(result)
    if type(result) ~= "table" or result.status ~= "selected"
        or type(result.text) ~= "string" or result.text == "" or type(result.replace) ~= "function" then
      showSafeError()
      return
    end
    beginOperation(promptPath, model, modelFailover, result.text, result.replace, true)
  end)
  return started ~= false
end

return M
