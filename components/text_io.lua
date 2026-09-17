local M = {}
local powerPointSelection = require("components.powerpoint_selection")

local POWERPOINT_BUNDLE_IDS = {
  ["com.microsoft.Powerpoint"] = true,
  ["com.microsoft.PowerPoint"] = true,
}
local SESSION_TIMEOUT = 10

local function startTask(task)
  if not task or type(task.start) ~= "function" then return false end
  local ok, result = pcall(task.start, task)
  return ok and result ~= false
end

local function stopTimer(timer)
  if timer and type(timer.stop) == "function" then pcall(timer.stop, timer) end
end

local function terminate(task)
  if task and type(task.terminate) == "function" then pcall(task.terminate, task) end
end

local function schedule(delay, callback)
  if type(hs) ~= "table" or type(hs.timer) ~= "table" or type(hs.timer.doAfter) ~= "function" then
    return nil
  end
  local ok, timer = pcall(hs.timer.doAfter, delay, callback)
  if not ok then return nil end
  return timer
end

local function helperPath()
  local source = debug and debug.getinfo and debug.getinfo(1, "S")
  source = source and source.source or ""
  if source:sub(1, 1) == "@" then source = source:sub(2) end
  local root = source:match("^(.*)/components/text_io%.lua$")
  if not root or root == "" then root = "." end
  return root .. "/helpers/replacement-engine/.build/release/replacement-engine"
end

local function defaultBundleID()
  if type(hs) ~= "table" or type(hs.application) ~= "table"
      or type(hs.application.frontmostApplication) ~= "function" then return nil end
  local ok, app = pcall(hs.application.frontmostApplication)
  if not ok or not app or type(app.bundleID) ~= "function" then return nil end
  local bundleOK, value = pcall(app.bundleID, app)
  if not bundleOK then return nil end
  return value
end

local function normalizeReadResult(result)
  if type(result) ~= "table" then return { status = "error" } end
  if result.status == "selected" and type(result.text) == "string" and result.text ~= "" then
    return { status = "selected", text = result.text, source = result.source }
  end
  if result.status == "none" or result.status == "unavailable" or result.status == "error" then
    return { status = result.status }
  end
  return { status = "error" }
end

local function newSwiftBackend()
  local active

  local function closeState(state, terminateHelper)
    if not state or state.done then return false end
    state.done = true
    stopTimer(state.watchdog)
    state.watchdog = nil
    if terminateHelper then terminate(state.helper) end
    if active == state then active = nil end
    return true
  end

  local function stop()
    local state = active
    active = nil
    if state and not state.done then
      state.done = true
      stopTimer(state.watchdog)
      state.watchdog = nil
      terminate(state.helper)
    end
    return true
  end

  local function protocolFailure(state)
    if not state or state.done then return end
    if not state.published then
      state.published = true
      local callback = state.callback
      closeState(state, true)
      callback({ status = "error" })
      return
    end
    local outcomeCallback = state.outcomeCallback
    closeState(state, true)
    if outcomeCallback then outcomeCallback({ outcome = "error", reason = "helper_protocol_failure" }) end
  end

  local function consume(state, stdout)
    if not state or state.done or type(stdout) ~= "string" or stdout == "" then return end
    state.buffer = (state.buffer or "") .. stdout
    while not state.done do
      local newline = state.buffer:find("\n", 1, true)
      if not newline then return end
      local line = state.buffer:sub(1, newline - 1)
      state.buffer = state.buffer:sub(newline + 1)
      if line ~= "" then
        local ok, event = pcall(hs.json.decode, line)
        if not ok or type(event) ~= "table" then protocolFailure(state); return end

        if state.mode == "read" then
          if state.published or event.event ~= "read" then protocolFailure(state); return end
          local result = normalizeReadResult(event)
          if result.status == "error" and event.status ~= "error" then protocolFailure(state); return end
          state.published = true
          closeState(state, false)
          state.callback(result)
          return
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
          state.published = true

          local function replace(replacement, outcomeCallback)
            if state.done or active ~= state or state.waitingOutcome or type(outcomeCallback) ~= "function"
                or type(replacement) ~= "string" or replacement == "" then return false end
            if not state.replacementEligible then
              closeState(state, true)
              outcomeCallback({ outcome = "not_replaced", reason = event.reason })
              return true
            end
            if type(hs.json) ~= "table" or type(hs.json.encode) ~= "function"
                or not state.helper or type(state.helper.setInput) ~= "function" then
              closeState(state, true)
              outcomeCallback({ outcome = "error", reason = "replacement_input_unavailable" })
              return false
            end
            local encodeOK, encoded = pcall(hs.json.encode, { replacement = replacement })
            if not encodeOK or type(encoded) ~= "string" then
              closeState(state, true)
              outcomeCallback({ outcome = "error", reason = "replacement_encode_failed" })
              return false
            end
            state.waitingOutcome = true
            state.outcomeCallback = outcomeCallback
            state.watchdog = schedule(SESSION_TIMEOUT, function()
              if active ~= state or state.done or not state.waitingOutcome then return end
              local cb = state.outcomeCallback
              closeState(state, true)
              if cb then cb({ outcome = "error", reason = "replacement_outcome_timeout" }) end
            end)
            if not state.watchdog then
              local cb = state.outcomeCallback
              closeState(state, true)
              if cb then cb({ outcome = "error", reason = "replacement_timer_unavailable" }) end
              return false
            end
            local inputOK, inputResult = pcall(state.helper.setInput, state.helper, encoded .. "\n")
            if not inputOK or inputResult == false then
              local cb = state.outcomeCallback
              closeState(state, true)
              if cb then cb({ outcome = "error", reason = "replacement_input_failed" }) end
              return false
            end
            return true
          end

          state.callback({
            status = "selected",
            text = event.selection,
            source = event.source,
            replace = replace,
          })
          return
        end

        if event.event == "outcome" then
          if not state.captureReceived or not state.waitingOutcome or type(event.outcome) ~= "string" then
            protocolFailure(state); return
          end
          local valid = event.outcome == "verified_replaced"
            or event.outcome == "replacement_dispatched_unverified"
            or event.outcome == "not_replaced"
            or event.outcome == "error"
          if not valid then protocolFailure(state); return end
          local callback = state.outcomeCallback
          closeState(state, false)
          if callback then callback({ outcome = event.outcome, reason = event.reason }) end
          return
        end

        protocolFailure(state)
        return
      end
    end
  end

  local function capture(mode, callback)
    if mode ~= "read" and mode ~= "replace" then return false end
    if type(callback) ~= "function" then return false end
    stop()
    if type(hs) ~= "table" or type(hs.task) ~= "table" or type(hs.task.new) ~= "function"
        or type(hs.json) ~= "table" or type(hs.json.decode) ~= "function" then
      callback({ status = "error" })
      return false
    end

    local state = {
      mode = mode,
      callback = callback,
      done = false,
      published = false,
      captureReceived = false,
      replacementEligible = false,
      waitingOutcome = false,
      outcomeCallback = nil,
      helper = nil,
      watchdog = nil,
      buffer = "",
    }
    active = state

    local function taskCallback(exitCode, stdout, _)
      if state.done then return end
      if type(stdout) == "string" and stdout ~= "" then consume(state, stdout) end
      if state.done then return end
      if exitCode ~= 0 then protocolFailure(state); return end
      if mode == "read" and not state.published then protocolFailure(state); return end
      if mode == "replace" then
        if not state.captureReceived or state.waitingOutcome then protocolFailure(state); return end
        closeState(state, false)
      end
    end

    local function streamCallback(_, stdout, _)
      consume(state, stdout)
      return not state.done
    end

    local arguments = mode == "read" and { "read" } or {}
    local createOK, helper = pcall(hs.task.new, helperPath(), taskCallback, streamCallback, arguments)
    if not createOK or not helper then
      active = nil
      state.done = true
      state.published = true
      callback({ status = "error" })
      return false
    end
    state.helper = helper
    if not startTask(helper) then
      state.published = true
      closeState(state, true)
      callback({ status = "error" })
      return false
    end

    if mode == "replace" then
      state.watchdog = schedule(SESSION_TIMEOUT, function()
        if active ~= state or state.done or state.captureReceived then return end
        if not state.published then
          state.published = true
          local cb = state.callback
          closeState(state, true)
          cb({ status = "error" })
        else
          closeState(state, true)
        end
      end)
      if not state.watchdog then
        state.published = true
        closeState(state, true)
        callback({ status = "error" })
        return false
      end
    end
    return true
  end

  return { capture = capture, stop = stop }
end

local function newPowerPointBackend()
  local function capture(mode, callback)
    if (mode ~= "read" and mode ~= "replace") or type(callback) ~= "function" then return false end
    local ok, snapshot = pcall(powerPointSelection.capture)
    if not ok then callback({ status = "error" }); return false end
    if not snapshot or type(snapshot.selectedText) ~= "string" or snapshot.selectedText == "" then
      callback({ status = "none" })
      return true
    end
    if mode == "read" then
      callback({ status = "selected", text = snapshot.selectedText, source = "powerpoint" })
      return true
    end
    callback({
      status = "selected",
      text = snapshot.selectedText,
      source = "powerpoint",
      replace = function(replacement, outcomeCallback)
        if type(replacement) ~= "string" or replacement == "" or type(outcomeCallback) ~= "function" then
          return false
        end
        local writeOK, outcome, reason = pcall(powerPointSelection.writeSelection, snapshot, replacement)
        if not writeOK then
          outcomeCallback({ outcome = "error", reason = "powerpoint_write_failed" })
          return false
        end
        if outcome ~= "verified_replaced" and outcome ~= "replacement_dispatched_unverified"
            and outcome ~= "not_replaced" and outcome ~= "error" then
          outcomeCallback({ outcome = "error", reason = "powerpoint_outcome_invalid" })
          return false
        end
        outcomeCallback({ outcome = outcome, reason = reason })
        return true
      end,
    })
    return true
  end
  return { capture = capture, stop = function() return true end }
end

function M.new(options)
  options = options or {}
  local currentBundleID = options.currentBundleID or defaultBundleID
  local swiftBackend = options.swiftBackend or newSwiftBackend()
  local powerPointBackend = options.powerPointBackend or newPowerPointBackend()
  local instance = {}

  function instance.capture(mode, callback)
    if (mode ~= "read" and mode ~= "replace") or type(callback) ~= "function" then return false end
    local ok, bundleID = pcall(currentBundleID)
    if not ok then callback({ status = "error" }); return false end
    local backend = POWERPOINT_BUNDLE_IDS[bundleID] and powerPointBackend or swiftBackend
    if type(backend) ~= "table" or type(backend.capture) ~= "function" then
      callback({ status = "error" })
      return false
    end
    return backend.capture(mode, function(result)
      if mode == "read" then callback(normalizeReadResult(result)); return end
      if type(result) ~= "table" then callback({ status = "error" }); return end
      if result.status == "selected" and type(result.text) == "string" and result.text ~= ""
          and type(result.replace) == "function" then
        callback(result)
      elseif result.status == "none" or result.status == "unavailable" or result.status == "error" then
        callback({ status = result.status })
      else
        callback({ status = "error" })
      end
    end)
  end

  function instance.stop()
    if type(swiftBackend) == "table" and type(swiftBackend.stop) == "function" then pcall(swiftBackend.stop) end
    if type(powerPointBackend) == "table" and type(powerPointBackend.stop) == "function" then pcall(powerPointBackend.stop) end
    return true
  end

  return instance
end

local defaultInstance
local function default()
  if not defaultInstance then defaultInstance = M.new() end
  return defaultInstance
end

function M.capture(mode, callback) return default().capture(mode, callback) end
function M.stop() return default().stop() end

return M
