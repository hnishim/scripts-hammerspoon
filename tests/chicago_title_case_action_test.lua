-- Tests own only the Chicago action boundary. Selection/replacement internals belong to text_io.
package.path = "./?.lua;./?/init.lua;" .. package.path
local captures, writes, alerts = {}, {}, {}
local converterCalls = {}
local converter = {
  convert = function(text)
    converterCalls[#converterCalls + 1] = text
    if text == "explode" then error("injected transform failure") end
    return (text:gsub("^foo", "Foo"))
  end,
}
local captureResult = true
local io = {
  capture = function(mode, callback)
    captures[#captures + 1] = { mode = mode, callback = callback }
    return captureResult
  end,
  stop = function() return true end,
}
package.preload["components.text_io"] = function() return io end
package.preload["components.chicago_title_case"] = function() return converter end
package.preload["components.powerpoint_selection"] = function()
  error("Chicago action must not own PowerPoint selection")
end
_G.hs = { alert = { show = function(message) alerts[#alerts + 1] = message end } }
local action = require("actions.chicago_title_case")
assert(type(action.run) == "function", "Chicago action exports run()")
assert(type(action.stop) == "function", "Chicago action exports stop() to invalidate stale callbacks")
local function equal(actual, expected, reason)
  assert(actual == expected, string.format("%s: expected %s, got %s", reason, tostring(expected), tostring(actual)))
end
local function begin()
  local before = #captures
  assert(action.run() ~= false, "capture begins")
  equal(#captures, before + 1, "one shared capture")
  local request = captures[#captures]
  equal(request.mode, "replace", "shared replace mode")
  return request
end
local function selection(input, options)
  options = options or {}
  local callbacks = {}
  local request = begin()
  local replace = options.replace
  if replace == nil then
    replace = function(value, callback)
      writes[#writes + 1] = { value = value, callback = callback }
      if options.outcome then callback({ outcome = options.outcome }) end
      return options.started == nil and true or options.started
    end
  end
  request.callback({ status = "selected", text = input, replace = replace })
  return request, callbacks
end

-- A captured session is the only write-back route; no direct clipboard or accessibility access.
do
  local before = #writes
  selection("foo and the api", { outcome = "verified_replaced" })
  equal(#writes, before + 1, "selected content writes once")
  equal(writes[#writes].value, "Foo and the api", "converted content is passed to session")
end

-- Existing title casing requires no mutation.
do
  local before = #writes
  selection("unchanged")
  equal(#writes, before, "unchanged selection does not write")
end

-- No selection, acquisition failure, invalid capture and conversion exception all fail closed.
for _, result in ipairs({
  { status = "none" }, { status = "unavailable" }, { status = "error" },
  { status = "selected", text = "" }, { status = "selected", text = false },
  { status = "selected", text = "foo", replace = false },
}) do
  local request = begin()
  local before = #writes
  request.callback(result)
  equal(#writes, before, "invalid capture cannot write: " .. tostring(result.status))
end
do
  local before = #writes
  selection("explode")
  equal(#writes, before, "conversion exception does not write")
end

-- Duplicate capture callback may never trigger a second write.
do
  local request = begin()
  local before = #writes
  local result = { status = "selected", text = "foo", replace = function(value, callback)
    writes[#writes + 1] = { value = value, callback = callback }
    callback({ outcome = "verified_replaced" })
    return true
  end }
  request.callback(result)
  request.callback(result)
  equal(#writes, before + 1, "duplicate capture callback writes only once")
end

-- Earlier capture callbacks are stale after a subsequent invocation.
do
  local prior = begin()
  local current = begin()
  local before = #writes
  prior.callback({ status = "selected", text = "foo", replace = function()
    error("stale capture callback must not write")
  end })
  equal(#writes, before, "stale callback ignored")
  current.callback({ status = "none" })
end

-- Stop invalidates pending callbacks without attempting write-back.
do
  local request = begin()
  local before = #writes
  action.stop()
  request.callback({ status = "selected", text = "foo", replace = function()
    error("stopped capture callback must not write")
  end })
  equal(#writes, before, "stopped callback ignored")
end

-- Once dispatch occurred, unknown outcome must not cause retry or fallback mutation.
for _, outcome in ipairs({ "verified_replaced", "replacement_dispatched_unverified", "not_replaced", "error" }) do
  local before = #writes
  selection("foo", { outcome = outcome })
  equal(#writes, before + 1, outcome .. " dispatches once")
end
do
  local before = #writes
  selection("foo", { started = false })
  equal(#writes, before + 1, "write-back rejection does not retry")
end
print("chicago_title_case_action_test: ok")
