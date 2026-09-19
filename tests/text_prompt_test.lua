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
  view.allowTextEntry, view.allowGestures, view.transparent, view.opaque = chain, chain, chain, chain
  function view:shadow(value) self.shadowEnabled = value; return self end
  function view:closeOnEscape(value) self.escapeEnabled = value; return self end
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
    if failures.delete == "raise" then error("delete failed") end
    if failures.delete == "return" then return false end
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
      function controller:setCallback(cb)
        if failures.controllerCallback then error("controller callback registration failed") end
        self.callback = cb
        return self
      end
      function controller:injectScript(_) return self end
      controllers[#controllers + 1] = controller
      return controller
    end },
  },
  eventtap = {
    event = { types = { keyDown = 10 } },
    new = function(_, cb)
      if failures.tapNew then error("event tap construction failed") end
      local tap = { callback = cb, active = false, startCount = 0, stopCount = 0, deleteCount = 0 }
      function tap:start()
        self.startCount = self.startCount + 1
        if failures.tapStart then error("event tap start failed") end
        self.active = true
        return self
      end
      function tap:stop()
        self.stopCount = self.stopCount + 1
        self.active = false
        if failures.tapStop == "raise" then error("event tap stop failed") end
        if failures.tapStop == "return" then return false end
        return self
      end
      function tap:delete()
        self.deleteCount = self.deleteCount + 1
        self.deleted = true
        self.active = false
        if failures.tapDelete == "raise" then error("event tap deletion failed") end
        if failures.tapDelete == "return" then return false end
        return self
      end
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
-- Enter on the text field and a click on Submit must share the form's
-- submit event path through the WKWebView message bridge. This checks the
-- generated HTML contract; real keyboard delivery is a macOS acceptance check.
local formHTML = views[1].htmlValue
assert(formHTML:match("<form[^>]*>"), "input has a real HTML form")
assert(formHTML:match("<input[^>]*>"), "form has a single-line input accepting Enter")
assert(formHTML:match("<button[^>]*type%s*=%s*['\"]?submit") or
  formHTML:match("<input[^>]*type%s*=%s*['\"]?submit"),
  "form has a submit control")
assert(formHTML:match("addEventListener%s*%(%s*['\"]submit['\"]") or
  formHTML:match("<form[^>]*onsubmit%s*="),
  "form submission is handled for both Enter and Submit")
assert(formHTML:match("postMessage%s*%(") and
  formHTML:match("action%s*:%s*['\"]submit['\"]"),
  "form submit sends a submit action through the WebView message bridge")
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


-- Focus loss must return key handling to the background application, and
-- subsequent focus acquisition must safely re-enable only this panel's tap.
started, index = request()
assert(started ~= false, "focus-transition input starts")
local focusView = views[#views]
focusView.windowCallbackFn("focusChange", focusView, true)
local focusTap = taps[#taps]
assert(focusTap and focusTap.active, "focused prompt monitor is active")
focusView.windowCallbackFn("focusChange", focusView, false)
eq(focusTap.active, false, "focus loss stops input key monitoring")
eq(focusTap.callback(cmdW), false, "background Cmd-W is not consumed")
focusView.windowCallbackFn("focusChange", focusView, true)
assert(focusTap.active, "focus recovery restarts scoped monitoring")
eq(focusTap.callback(cmdW), true, "refocused Cmd-W is consumed")
eq(results[index].status, "cancelled", "refocused close cancels")
eq(callbacks[index], 1, "focus transitions produce one cancellation")

-- A focused close key must be consumed independently of cleanup success.
-- After the attempted cleanup, a stale tap cannot intercept background keys.
local function assertCloseFailure(label, kind, mode)
  failures[kind] = mode
  local ok, current = request()
  assert(ok ~= false, label .. ": prompt starts")
  local view = views[#views]
  view.windowCallbackFn("focusChange", view, true)
  local tap = taps[#taps]
  assert(tap and tap.active, label .. ": focused monitor started")
  eq(tap.callback(cmdW), true, label .. ": Cmd-W is consumed despite cleanup failure")
  eq(results[current].status, "cancelled", label .. ": completion cancels")
  eq(callbacks[current], 1, label .. ": completion published exactly once")
  eq(view.deleteCount, 1, label .. ": view cleanup attempted")
  eq(tap.stopCount, 1, label .. ": monitor stop attempted")
  eq(tap.deleteCount, 1, label .. ": monitor delete attempted")
  eq(tap.callback(cmdW), false, label .. ": stale monitor passes background Cmd-W")
  failures[kind] = nil
  local restarted, fresh = request()
  assert(restarted ~= false, label .. ": new input starts after cleanup failure")
  send("cancel")
  eq(results[fresh].status, "cancelled", label .. ": next input works")
  eq(callbacks[fresh], 1, label .. ": next input completes once")
end

assertCloseFailure("WebView deletion error", "delete", "raise")
assertCloseFailure("event monitor stop error", "tapStop", "raise")
assertCloseFailure("event monitor deletion error", "tapDelete", "return")

-- Input startup failures must not leave an orphaned WebView or event monitor.
local function assertStartupFailure(label, kind)
  failures[kind] = true
  local viewBefore, tapBefore = #views, #taps
  local startedOK, current = request()
  if kind == "tapStart" then
    assert(startedOK ~= false, label .. ": view starts before focus activation")
    local view = views[#views]
    view.windowCallbackFn("focusChange", view, true)
  else
    eq(startedOK, false, label .. ": request cannot start")
  end
  eq(results[current].status, "error", label .. ": error is reported")
  eq(callbacks[current], 1, label .. ": error callback is delivered once")
  local view = views[#views]
  if #views > viewBefore then
    eq(view.deleteCount, 1, label .. ": created view cleanup attempted")
  end
  if #taps > tapBefore then
    local tap = taps[#taps]
    assert(not tap.active, label .. ": failed monitor is inactive")
    eq(tap.deleteCount, 1, label .. ": failed monitor delete attempted")
    eq(tap.callback(cmdW), false, label .. ": failed monitor ignores background key")
  end
  failures[kind] = nil
  local recovered, fresh = request()
  assert(recovered ~= false, label .. ": later input starts")
  send("cancel")
  eq(results[fresh].status, "cancelled", label .. ": later input cancels")
  eq(callbacks[fresh], 1, label .. ": later input completes once")
end

assertStartupFailure("user content controller creation", "controller")
assertStartupFailure("controller callback registration", "controllerCallback")
assertStartupFailure("event monitor construction", "tapNew")
assertStartupFailure("event monitor start", "tapStart")


-- Input/result must share their basic visual language without fixing a
-- particular color code, type size or exact layout pixels in regression tests.
-- The real appearance remains a Local/Human Acceptance item.
package.preload["components.hud"] = function()
  return { showTransient = function() return true end }
end
local resultPanel = require("components.result_panel")
local styleStarted, styleIndex = request()
assert(styleStarted ~= false, "input style fixture starts")
local inputView = views[#views]
assert(inputView.htmlValue and inputView.htmlValue:find("<form", 1, true), "input style fixture renders a form")
send("cancel")
eq(results[styleIndex].status, "cancelled", "input style fixture cleaned up")
assert(resultPanel.show("result content"), "result style fixture starts")
local resultView = views[#views]

local function cssValue(html, property)
  local found = html and html:match(property .. "%s*:%s*([^;}]+)")
  if found then found = found:match("^%s*(.-)%s*$") end
  assert(found and found ~= "", "visual style exposes " .. property)
  return found
end
eq(cssValue(inputView.htmlValue, "background"), cssValue(resultView.htmlValue, "background"),
  "input and result share panel background")
eq(cssValue(inputView.htmlValue, "font%-family"), cssValue(resultView.htmlValue, "font%-family"),
  "input and result share typeface")
cssValue(inputView.htmlValue, "padding")
cssValue(resultView.htmlValue, "padding")
cssValue(inputView.htmlValue, "border%-radius")
cssValue(resultView.htmlValue, "border%-radius")
eq(inputView.shadowEnabled, true, "input uses a window shadow")
eq(resultView.shadowEnabled, true, "result uses a window shadow")
assert(resultPanel.stop(), "result style fixture closes")

print("text_prompt_test: ok")
