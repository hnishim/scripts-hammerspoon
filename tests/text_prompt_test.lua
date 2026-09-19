-- Behavioral tests for the asynchronous custom WebView input contract.
-- The mock covers Lua/browser callbacks; real WKWebView focus and native key
-- propagation are reserved for Local Acceptance on macOS.
local views, controllers, taps = {}, {}, {}
local failures = {}
local callbacks, results = {}, {}
local function eq(actual, expected, context)
  assert(actual == expected, string.format("%s: expected %s, got %s", context, tostring(expected), tostring(actual)))
end

local function chain(self) return self end
local function newView(frame)
  local view = { frame = frame, shown = false, deleted = false }
  view.windowStyle, view.windowTitle, view.level = chain, chain, chain
  view.allowTextEntry, view.allowGestures, view.shadow = chain, chain, chain
  view.closeOnEscape, view.transparent, view.opaque = chain, chain, chain
  function view:windowCallback(cb) self.windowCallbackFn = cb; return self end
  function view:userContentController(controller) self.controller = controller; return self end
  function view:html(value) self.htmlValue = value; return self end
  function view:show()
    if failures.show then error("show failed") end
    self.shown = true
    return self
  end
  function view:delete()
    self.deleted = true
    self.deleteCount = (self.deleteCount or 0) + 1
    if failures.delete then error("delete failed") end
    return true
  end
  views[#views + 1] = view
  return view
end

_G.hs = {
  drawing = { windowLevels = { floating = 1 } },
  screen = { mainScreen = function()
    return { frame = function() return { x = 0, y = 0, w = 1280, h = 900 } end }
  end },
  dialog = { textPrompt = function() error("native Hammerspoon dialog must not be used") end },
  webview = {
    new = function(frame, _, controller)
      if failures.new then error("new failed") end
      local view = newView(frame)
      view.controller = controller
      return view
    end,
    usercontent = { new = function(_)
      if failures.controller then error("controller failed") end
      local controller = {}
      function controller:setCallback(cb) self.callback = cb; return self end
      function controller:injectScript(_) return self end
      controllers[#controllers + 1] = controller
      return controller
    end },
  },
  eventtap = {
    event = { types = { keyDown = 10 } },
    new = function(_, cb)
      local tap = { callback = cb, active = false }
      function tap:start() self.active = true; return self end
      function tap:stop() self.active = false; return self end
      function tap:delete() self.deleted = true; self.active = false; return true end
      taps[#taps + 1] = tap
      return tap
    end,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
local prompt = require("components.text_prompt")

local function request()
  local index = #results + 1
  local started = prompt.request({
    title = "AI input", message = "Enter text", submit = "Run", cancel = "Cancel",
  }, function(result)
    results[index] = result
    callbacks[index] = (callbacks[index] or 0) + 1
  end)
  return started, index
end

local function send(action, value)
  local controller = controllers[#controllers]
  assert(controller and type(controller.callback) == "function", "WebView has a Lua message callback")
  controller.callback({ body = { action = action, text = value } })
end

local started, index = request()
assert(started ~= false, "custom WebView prompt starts")
eq(#views, 1, "one view created")
assert(views[1].shown, "input view is displayed")
assert(type(views[1].htmlValue) == "string" and views[1].htmlValue:find("<form", 1, true),
  "input view contains an HTML form")
eq(results[index], nil, "request does not report success before submission")
send("submit", "  entered text  ")
eq(results[index].status, "submitted", "submission status")
eq(results[index].text, "entered text", "submission trims text")
eq(callbacks[index], 1, "submission publishes exactly once")
eq(views[1].deleted, true, "submission releases the view")
send("submit", "late duplicate")
eq(callbacks[index], 1, "late message cannot submit twice")

started, index = request()
assert(started ~= false, "empty-input prompt starts")
send("submit", "  \t  ")
eq(results[index].status, "empty", "whitespace is an explicit empty result")
eq(callbacks[index], 1, "empty result is delivered exactly once")

started, index = request()
assert(started ~= false, "cancel prompt starts")
send("cancel")
eq(results[index].status, "cancelled", "cancel remains distinguishable from empty")
eq(results[index].text, nil, "cancel has no input text")
send("submit", "late completion")
eq(callbacks[index], 1, "cancel cannot be followed by submission")

-- Window Escape dismissal and focused Cmd-W are cancellation, not submission.
started, index = request()
assert(started ~= false, "Escape close prompt starts")
local escapeView = views[#views]
assert(type(escapeView.windowCallbackFn) == "function", "input view owns its close callback")
escapeView.windowCallbackFn("closing", escapeView)
eq(results[index].status, "cancelled", "native Escape/window close cancels")
eq(callbacks[index], 1, "native close reports once")

started, index = request()
assert(started ~= false, "Cmd-W prompt starts")
local closeView = views[#views]
closeView.windowCallbackFn("focusChange", closeView, true)
local keyTap = taps[#taps]
assert(keyTap and keyTap.active, "focused input monitors close key")
local cmdW = {
  getFlags = function() return { cmd = true } end,
  getKeyCode = function() return 13 end,
}
eq(keyTap.callback(cmdW), true, "focused Cmd-W is consumed")
eq(results[index].status, "cancelled", "Cmd-W cancels active input")
eq(callbacks[index], 1, "Cmd-W callback fires once")
eq(keyTap.active, false, "closing stops the key monitor")
eq(keyTap.callback(cmdW), false, "stale key monitor cannot consume background Cmd-W")

-- A second call while a prompt is visible must not create a second live form.
started, index = request()
assert(started ~= false, "pending prompt starts")
local existingViewCount = #views
local secondStart = prompt.request({ title = "Second" }, function() error("reentry must not complete") end)
eq(secondStart, false, "concurrent prompt request is rejected")
eq(#views, existingViewCount, "concurrent request does not create a new form")
send("cancel")
eq(results[index].status, "cancelled", "original prompt can still be cancelled")

-- Failures to construct or show a form publish an error and leave no active view.
failures.new = true
started, index = request()
eq(started, false, "view construction failure cannot start")
eq(results[index].status, "error", "view construction failure returns an error")
eq(callbacks[index], 1, "construction failure reports error once")
failures.new = nil

failures.show = true
started, index = request()
eq(started, false, "view display failure cannot start")
eq(results[index].status, "error", "view display failure returns an error")
eq(callbacks[index], 1, "display failure reports error once")
assert(views[#views].deleted, "failed display releases its view")
failures.show = nil

started, index = request()
assert(started ~= false, "new prompt starts after failures")
send("cancel")
eq(results[index].status, "cancelled", "recovered prompt completes")

print("text_prompt_test: ok")
