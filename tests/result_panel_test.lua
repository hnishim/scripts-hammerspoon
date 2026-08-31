local views = {}
local eventTaps = {}
local clipboard
local pasteboardAttempts = 0
local failures = {}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertTableEqual(actual, expected, message)
  assertEqual(#actual, #expected, message .. " length")
  for index, value in ipairs(expected) do assertEqual(actual[index], value, message .. "[" .. index .. "]") end
end

local function newView(frame)
  local view = { frame = frame, active = true, deleted = false, shown = false, callback = nil, htmlValue = nil }
  local function chain(self) return self end
  view.windowStyle, view.windowTitle, view.level, view.allowGestures = chain, chain, chain, chain
  view.allowTextEntry, view.closeOnEscape, view.shadow = chain, chain, chain
  function view:windowCallback(callback) self.callback = callback; return self end
  function view:html(value)
    if failures.html == "raise" then error("html failure") end
    if failures.html == "return" then return nil end
    self.htmlValue = value
    return self
  end
  function view:show()
    if failures.show == "raise" then error("show failure") end
    if failures.show == "return" then return nil end
    self.shown = true
    return self
  end
  function view:delete()
    self.deleteCount = (self.deleteCount or 0) + 1
    self.active = false
    if failures.delete == "raise" then error("delete failure") end
    if failures.delete == "return" then return false end
    self.deleted = true
  end
  views[#views + 1] = view
  return view
end

local function newEventTap(_, callback)
  local tap = { active = false, callback = callback, startCount = 0, stopCount = 0, deleteCount = 0 }
  function tap:start()
    self.startCount = self.startCount + 1
    self.active = true
    return self
  end
  function tap:stop()
    self.stopCount = self.stopCount + 1
    self.active = false
    if failures.stop == "raise" then error("stop failure") end
    if failures.stop == "return" then return false end
  end
  function tap:delete()
    self.deleteCount = self.deleteCount + 1
    self.active = false
    if failures.tapDelete == "raise" then error("event tap delete failure") end
    if failures.tapDelete == "return" then return false end
  end
  eventTaps[#eventTaps + 1] = tap
  return tap
end

_G.hs = {
  drawing = { windowLevels = { floating = 1 } },
  screen = { mainScreen = function() return { frame = function() return { x = 0, y = 0, w = 1200, h = 800 } end } end },
  webview = { new = function(frame)
    if failures.new == "raise" then error("new failure") end
    if failures.new == "return" then return nil end
    return newView(frame)
  end },
  pasteboard = { setContents = function(value)
    pasteboardAttempts = pasteboardAttempts + 1
    if failures.pasteboard == "raise" then error("pasteboard failure") end
    if failures.pasteboard == "return" then return false end
    clipboard = value
    return true
  end },
  eventtap = { new = newEventTap, event = { types = { keyDown = 10 } } },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
local panel = require("components.result_panel")

local function keyEvent(modifiers, keyCode)
  return {
    getType = function() return hs.eventtap.event.types.keyDown end,
    getFlags = function() local flags = {}; for _, value in ipairs(modifiers) do flags[value] = true end; return flags end,
    getKeyCode = function() return keyCode end,
  }
end

local content = '<tag attr="x">結果 & 詳細\n次の行</tag>'
assertEqual(panel.show(nil), false, "show returns false for invalid content")
assertEqual(#views, 0, "invalid show does not create a WebView")
assertEqual(#eventTaps, 0, "invalid show does not create an event tap")
assertEqual(panel.show(content), true, "show returns true after displaying valid content")
assertEqual(#views, 1, "show creates one WebView")
local firstView = views[1]
assertEqual(firstView.shown, true, "show displays the WebView")
assert(firstView.htmlValue:find("&lt;tag attr=&quot;x&quot;&gt;", 1, true), "HTML escapes tags and quotes")
assert(firstView.htmlValue:find("結果 &amp; 詳細<br>次の行", 1, true), "HTML escapes content and converts newlines")
assertEqual(#eventTaps, 1, "show creates one event tap")
assertEqual(eventTaps[1].startCount, 0, "event tap waits for focus")

firstView.callback("focusChange", true)
assertEqual(eventTaps[1].startCount, 1, "focus starts key monitoring")
assertEqual(eventTaps[1].callback(keyEvent({ "cmd" }, 13)), true, "Cmd-W is consumed")
assertEqual(firstView.deleted, true, "Cmd-W closes the displayed WebView")
assertEqual(eventTaps[1].stopCount, 1, "closing stops key monitoring")
assertEqual(eventTaps[1].deleteCount, 1, "closing removes key monitoring")

assertEqual(panel.show(content), true, "show returns true when reopening")
local secondView = views[2]
assertEqual(firstView.deleted, true, "reopen leaves the old WebView discarded")
secondView.callback("focusChange", true)
local secondTap = eventTaps[2]
assertEqual(secondTap.callback(keyEvent({ "cmd" }, 8)), true, "Cmd-C is consumed")
assertEqual(clipboard, content, "Cmd-C copies raw pre-HTML content")
assertEqual(secondTap.callback(keyEvent({ "cmd", "shift" }, 8)), false, "extra modifiers pass through")
assertEqual(secondTap.callback(keyEvent({ "cmd" }, 12)), false, "other keys pass through")

secondView.callback("focusChange", false)
assertEqual(secondTap.stopCount, 1, "focus loss stops key monitoring immediately")
assertEqual(secondTap.active, false, "focus loss leaves the monitor inactive")
assertEqual(secondTap.callback(keyEvent({ "cmd" }, 8)), false, "focus loss disables key monitoring")
assertEqual(panel.close(), true, "close returns true for the active WebView")
assertEqual(secondView.deleted, true, "close discards only the current WebView")
assertEqual(secondTap.stopCount, 1, "close stops the current event tap")
assertEqual(secondTap.deleteCount, 1, "close removes the current event tap")
assertEqual(panel.close(), false, "double close returns false")

assertEqual(panel.show("third"), true, "show returns true for the third WebView")
local thirdTap = eventTaps[3]
local thirdView = views[3]
thirdView.callback("focusChange", true)
assertEqual(panel.stop(), true, "stop returns true for the active WebView")
assertEqual(thirdView.deleted, true, "stop discards the WebView")
assertEqual(thirdTap.stopCount, 1, "stop halts monitoring")
assertEqual(thirdTap.deleteCount, 1, "stop removes the event tap")
assertEqual(thirdTap.callback(keyEvent({ "cmd" }, 8)), false, "stop leaves no active key monitoring")
assertEqual(panel.stop(), false, "stopped stop returns false")

for index, tap in ipairs(eventTaps) do
  assertEqual(tap.stopCount, 1, "event tap " .. index .. " is stopped")
  assertEqual(tap.deleteCount, 1, "event tap " .. index .. " is deleted")
end

local function resetFailures()
  failures.new, failures.html, failures.show = nil, nil, nil
  failures.delete, failures.stop, failures.tapDelete, failures.pasteboard = nil, nil, nil, nil
end

local function assertShowFailure(name, kind, mode)
  resetFailures()
  failures[kind] = mode
  local viewCount, tapCount = #views, #eventTaps
  assertEqual(panel.show("failure: " .. name), false, name .. " show returns false")
  assertEqual(#eventTaps, tapCount, name .. " creates no event tap")
  if kind == "html" or kind == "show" then
    assertEqual(#views, viewCount + 1, name .. " creates a WebView before display failure")
    assertEqual(views[#views].deleteCount, 1, name .. " attempts WebView cleanup")
    assertEqual(views[#views].active, false, name .. " leaves the failed WebView inactive")
  else
    assertEqual(#views, viewCount, name .. " creates no WebView")
  end
  resetFailures()
  assertEqual(panel.show("recovery after " .. name), true, name .. " leaves no active failed panel")
  assertEqual(panel.stop(), true, name .. " recovery panel stops")
end

assertShowFailure("hs.webview.new return failure", "new", "return")
assertShowFailure("hs.webview.new exception", "new", "raise")
assertShowFailure("view:html return failure", "html", "return")
assertShowFailure("view:html exception", "html", "raise")
assertShowFailure("view:show return failure", "show", "return")
assertShowFailure("view:show exception", "show", "raise")

local function assertCloseFailure(name, kind, mode)
  resetFailures()
  assertEqual(panel.show("cleanup: " .. name), true, name .. " setup displays")
  local view, tap = views[#views], eventTaps[#eventTaps]
  view.callback("focusChange", true)
  failures[kind] = mode
  assertEqual(panel.close(), false, name .. " close returns false")
  assertEqual(view.deleteCount, 1, name .. " attempts WebView release")
  assertEqual(tap.stopCount, 1, name .. " attempts event tap stop")
  assertEqual(tap.deleteCount, 1, name .. " attempts event tap delete")
  assertEqual(view.active, false, name .. " leaves the WebView inactive")
  assertEqual(tap.active, false, name .. " leaves the monitor inactive")
  local priorClipboard = clipboard
  assertEqual(tap.callback(keyEvent({ "cmd" }, 8)), false, name .. " old monitor does not consume Cmd-C")
  assertEqual(clipboard, priorClipboard, name .. " old monitor does not alter the clipboard")
  resetFailures()
  assertEqual(panel.close(), false, name .. " has no active panel after failed cleanup")
  assertEqual(view.deleteCount, 1, name .. " does not repeat WebView release")
  assertEqual(tap.stopCount, 1, name .. " does not repeat event tap stop")
  assertEqual(tap.deleteCount, 1, name .. " does not repeat event tap delete")
  assertEqual(panel.show("recovery after " .. name), true, name .. " leaves no active state")
  assertEqual(panel.stop(), true, name .. " recovery panel stops")
end

assertCloseFailure("view:delete return failure", "delete", "return")
assertCloseFailure("view:delete exception", "delete", "raise")
assertCloseFailure("event tap stop return failure", "stop", "return")
assertCloseFailure("event tap stop exception", "stop", "raise")
assertCloseFailure("event tap delete return failure", "tapDelete", "return")
assertCloseFailure("event tap delete exception", "tapDelete", "raise")

local function assertCopyFailure(name, mode)
  resetFailures()
  assertEqual(panel.show("copy failure: " .. name), true, name .. " setup displays")
  local tap = eventTaps[#eventTaps]
  local view = views[#views]
  view.callback("focusChange", true)
  local priorClipboard, priorAttempts = clipboard, pasteboardAttempts
  failures.pasteboard = mode
  assertEqual(tap.callback(keyEvent({ "cmd" }, 8)), false, name .. " Cmd-C is not consumed")
  assertEqual(clipboard, priorClipboard, name .. " preserves the raw clipboard value")
  assertEqual(pasteboardAttempts, priorAttempts + 1, name .. " attempts one clipboard write")
  assertEqual(tap.active, true, name .. " keeps monitoring active after copy failure")
  resetFailures()
  assertEqual(panel.close(), true, name .. " cleanup succeeds after copy failure")
end

assertCopyFailure("pasteboard return failure", "return")
assertCopyFailure("pasteboard exception", "raise")

local function assertStopFailure(name, kind, mode)
  resetFailures()
  assertEqual(panel.show("stop cleanup: " .. name), true, name .. " setup displays")
  local view, tap = views[#views], eventTaps[#eventTaps]
  view.callback("focusChange", true)
  failures[kind] = mode
  assertEqual(panel.stop(), false, name .. " stop returns false")
  assertEqual(view.deleteCount, 1, name .. " attempts WebView release")
  assertEqual(tap.stopCount, 1, name .. " attempts event tap stop")
  assertEqual(tap.deleteCount, 1, name .. " attempts event tap delete")
  assertEqual(view.active, false, name .. " leaves the WebView inactive")
  assertEqual(tap.active, false, name .. " leaves the monitor inactive")
  assertEqual(tap.callback(keyEvent({ "cmd" }, 8)), false, name .. " old monitor does not consume Cmd-C")
  resetFailures()
  assertEqual(panel.stop(), false, name .. " has no active panel after failed cleanup")
  assertEqual(view.deleteCount, 1, name .. " does not repeat WebView release")
  assertEqual(tap.stopCount, 1, name .. " does not repeat event tap stop")
  assertEqual(tap.deleteCount, 1, name .. " does not repeat event tap delete")
  assertEqual(panel.show("recovery after " .. name), true, name .. " leaves no active state")
  assertEqual(panel.stop(), true, name .. " recovery panel stops")
end

assertStopFailure("view:delete return failure", "delete", "return")
assertStopFailure("view:delete exception", "delete", "raise")
assertStopFailure("event tap stop return failure", "stop", "return")
assertStopFailure("event tap stop exception", "stop", "raise")
assertStopFailure("event tap delete return failure", "tapDelete", "return")
assertStopFailure("event tap delete exception", "tapDelete", "raise")

print("result_panel_test: ok")
