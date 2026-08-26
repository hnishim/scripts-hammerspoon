local M = {}

local modifiers = { "cmd", "alt", "shift" }
local keychainService = "com.hnishim.raycast-gemini"
local keychainTimeout = 10
local httpTimeout = 65
local operationSequence = 0
local commands = {
  B = { prompt = "/Users/hnishim/Library/Mobile Documents/com~apple~CloudDocs/Dev/prompts/ai-commands/bio-ai_expert.md", model = "gemini-flash-lite-latest" },
  R = { prompt = "/Users/hnishim/Library/Mobile Documents/com~apple~CloudDocs/Dev/prompts/ai-commands/review-text_compact.md", model = "gemini-flash-lite-latest" },
  T = { prompt = "/Users/hnishim/Library/Mobile Documents/com~apple~CloudDocs/Dev/prompts/ai-commands/translate.md", model = "gemini-flash-lite-latest" },
}

local activeTask
local resultWindow

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

local function htmlEscape(value)
  return value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    :gsub('"', "&quot;"):gsub("'", "&#39;"):gsub("\n", "<br>")
end

local function clearResultWindow(deleteWindow)
  if deleteWindow and resultWindow then
    local window = resultWindow
    resultWindow = nil
    window:delete()
  else
    resultWindow = nil
  end
end

local function showResult(response)
  clearResultWindow(true)
  local screenFrame = hs.screen.mainScreen():frame()
  local width, height = 760, 540
  local frame = { x = screenFrame.x + (screenFrame.w - width) / 2, y = screenFrame.y + (screenFrame.h - height) / 2, w = width, h = height }
  local html = [[<!doctype html><html lang="ja"><head><meta charset="utf-8"><style>
    html, body { background: #1e1e22; color: #f5f5f7; margin: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
    main { box-sizing: border-box; padding: 28px; white-space: normal; line-height: 1.65; }
    .result { font-size: 17px; overflow-wrap: anywhere; }
  </style></head><body><main><div class="result">]] .. htmlEscape(response) .. [[</div></main></body></html>]]
  resultWindow = hs.webview.new(frame):windowStyle({ "titled", "closable", "resizable" })
    :windowTitle("Gemini result"):level(hs.drawing.windowLevels.floating):allowGestures(false)
    :allowTextEntry(false):closeOnEscape(true):shadow(true)
    :windowCallback(function(action) if action == "closing" then clearResultWindow(false) end end)
    :html(html):show()
end

local function acquireSelection()
  if not hs.uielement or not hs.uielement.focusedElement then showSafeError(); return nil, false end
  local focusedOK, focused = pcall(hs.uielement.focusedElement)
  if not focusedOK or not focused then showSafeError(); return nil, false end
  local selectedOK, selection = pcall(function() return focused:selectedText() end)
  if not selectedOK or selection == nil then showSafeError(); return nil, false end
  return selection, true
end

local function frontmost(target)
  local ok, value = pcall(function() return target:isFrontmost() end)
  return ok and value == true
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

local function stableClipboardSnapshot()
  local beforeOK, before = changeCount()
  if not beforeOK then return false end
  local contentsOK, contents = clipboardContents()
  if not contentsOK then return false end
  local afterOK, after = changeCount()
  if not afterOK or before ~= after then return false end
  return true, contents, after
end

local function finishReplace(target, response, complete)
  local function done(errorMessage)
    complete(errorMessage)
  end
  local function restoreIfUntouched(prior, postCount, reportError)
    local currentOK, current, currentCount = stableClipboardSnapshot()
    if not currentOK then done("error"); return end
    if current ~= response or currentCount ~= postCount then done(reportError and "error" or nil); return end
    local restored = prior == nil and clearContents() or setContents(prior)
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
  local priorOK, prior, beforeCount = stableClipboardSnapshot()
  if not priorOK or not setContents(response) then scheduleError(); return end
  local responseOK, current, postCount = stableClipboardSnapshot()
  if not responseOK or current ~= response or postCount ~= beforeCount + 1 then scheduleError(); return end
  if not frontmost(target) then scheduleError(); return end
  local beforePasteOK, beforePaste, beforePasteCount = stableClipboardSnapshot()
  if not beforePasteOK or beforePaste ~= response or beforePasteCount ~= postCount then scheduleError(); return end
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
      finishReplace(target, response, function(errorMessage) release(state, errorMessage) end)
      return
    end
    local showOK = pcall(showResult, response)
    release(state, not showOK)
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

local function runPrompt(command)
  local button, input = hs.dialog.textPrompt("Gemini AI command", "Geminiへ渡すテキストを入力してください。", "", "実行", "キャンセル")
  if button ~= "実行" then return end
  input = trim(input)
  if input == "" then showMessage("入力テキストが空です。"); return end
  M.run(command, input, "display", nil)
end

function M.run(command, input, requestedOutput, target)
  if activeTask then showMessage("別のAIコマンドを実行中です。"); return end
  if type(command) ~= "table" or type(input) ~= "string" then showSafeError(); return end
  local promptOK, template = readFile(command.prompt)
  if not promptOK then showSafeError(); return end
  local renderedOK, prompt = replacePromptPlaceholders(template, input)
  if not renderedOK then showSafeError(); return end
  operationSequence = operationSequence + 1
  local state = { token = operationSequence, done = false, keyTask = nil, watchdog = nil }
  activeTask = state
  startKeychain(state, command, prompt, target)
end

local function invoke(command, key)
  if activeTask then showMessage("別のAIコマンドを実行中です。"); return end
  local target
  if key == "R" or key == "T" then
    local ok
    ok, target = pcall(hs.application.frontmostApplication)
    if not ok or not target then showSafeError(); return end
  end
  local selection, acquired = acquireSelection()
  if not acquired then return end
  if selection == "" then runPrompt(command); return end
  M.run(command, selection, "display", target)
end

function M.start()
  for key, command in pairs(commands) do hs.hotkey.bind(modifiers, key, function() invoke(command, key) end) end
end

return M
