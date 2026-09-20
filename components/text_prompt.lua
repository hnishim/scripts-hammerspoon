local M = {}
local current

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function escape(value)
  return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
    :gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;")
end

local function call(object, method, ...)
  if not object or type(object[method]) ~= "function" then return false end
  local ok, result = pcall(object[method], object, ...)
  return ok and result ~= nil and result ~= false
end

local function cleanup(form)
  if form.cleaned then return end
  form.cleaned = true
  form.active = false
  form.focused = false
  if current == form then current = nil end
  if form.tap then
    pcall(form.tap.stop, form.tap)
    if type(form.tap.delete) == "function" then pcall(form.tap.delete, form.tap) end
  end
  if form.view then pcall(form.view.delete, form.view) end
end

local function finish(form, result)
  if not form.active then return false end
  local callback = form.callback
  cleanup(form)
  if type(callback) == "function" then pcall(callback, result) end
  return true
end

local function fail(form)
  finish(form, { status = "error" })
  return false
end

local function handleMessage(form, message)
  if current ~= form or not form.active then return end
  local body = type(message) == "table" and message.body or nil
  if type(body) ~= "table" then return end
  if body.action == "cancel" then
    finish(form, { status = "cancelled" })
  elseif body.action == "submit" then
    if type(body.text) ~= "string" then fail(form); return end
    local value = trim(body.text)
    if value == "" then finish(form, { status = "empty" })
    else finish(form, { status = "submitted", text = value }) end
  end
end

local function isCommandW(event)
  if not event or type(event.getFlags) ~= "function"
      or type(event.getKeyCode) ~= "function" then return false end
  local ok, flags = pcall(event.getFlags, event)
  if not ok or type(flags) ~= "table" or not flags.cmd then return false end
  for key in pairs(flags) do if key ~= "cmd" then return false end end
  local keyOK, keyCode = pcall(event.getKeyCode, event)
  return keyOK and keyCode == 13
end

local function handleKey(form, event)
  if current ~= form or not form.active or not form.focused
      or not form.monitorActive or not isCommandW(event) then return false end
  finish(form, { status = "cancelled" })
  -- Consume the focused close key regardless of cleanup API failures.
  return true
end

local function onWindow(form, action, focused)
  if current ~= form or not form.active then return end
  if action == "closing" then
    finish(form, { status = "cancelled" })
  elseif action == "focusChange" then
    if focused == true then
      if form.monitorActive then return end
      local ok, started = pcall(form.tap.start, form.tap)
      if not ok or started == false or started == nil then
        fail(form)
      else
        form.monitorActive = true
        form.focused = true
      end
    else
      form.focused = false
      if form.monitorActive then
        form.monitorActive = false
        pcall(form.tap.stop, form.tap)
      end
    end
  end
end

local function screenFrame()
  if not hs or not hs.screen or type(hs.screen.mainScreen) ~= "function" then return nil end
  local ok, screen = pcall(hs.screen.mainScreen)
  if not ok or not screen or type(screen.frame) ~= "function" then return nil end
  local frameOK, frame = pcall(screen.frame, screen)
  if not frameOK or type(frame) ~= "table" then return nil end
  if type(frame.w) ~= "number" or type(frame.h) ~= "number" then return nil end
  return frame
end

local function focusInput(form)
  if current ~= form or not form.active or not form.view then return false end

  local broughtForward = call(form.view, "bringToFront", false)
  local focusedWindow = false
  if type(form.view.hswindow) == "function" then
    local windowOK, window = pcall(form.view.hswindow, form.view)
    if windowOK and window and type(window.focus) == "function" then
      local focusOK, result = pcall(window.focus, window)
      focusedWindow = focusOK and result ~= false
    end
  end

  local focusedField = call(form.view, "evaluateJavaScript",
    "document.getElementById('value').focus();")
  return broughtForward or focusedWindow or focusedField
end

local function showView(form)
  if current ~= form or not form.active or not form.view then return false end
  if form.shown then return focusInput(form) end
  if not call(form.view, "show") then
    fail(form)
    return false
  end
  form.shown = true
  focusInput(form)
  return true
end

local function handleNavigation(form, action)
  if action == "didFinishNavigation" or action == "didFailNavigation"
      or action == "didFailProvisionalNavigation" then
    form.navigationFinished = true
    if current == form then showView(form) end
  end
end

local function html(options)
  local title = escape(options.title or "Input")
  local message = escape(options.message or "")
  local submit = escape(options.submit or "Submit")
  local cancel = escape(options.cancel or "Cancel")
  return [[<!doctype html><html lang="en"><head><meta charset="utf-8"><style>
    html, body { width: 100%; height: 100%; min-height: 100%;
      background: rgba(24, 24, 28, 0.86); color: #f5f5f7; margin: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; overflow: hidden; }
    main { box-sizing: border-box; min-height: 100%; padding: 28px; border-radius: 16px; }
    h1 { font-size: 18px; font-weight: 500; margin: 0 0 12px; }
    label { display: block; font-size: 14px; line-height: 1.5; margin-bottom: 12px; }
    input { box-sizing: border-box; display: block; width: 100%; border: 1px solid #767681;
      border-radius: 8px; padding: 10px 12px; background: #303036; color: #fff;
      font: inherit; outline-offset: 2px; }
    .actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 20px; }
    button { border: 0; border-radius: 8px; padding: 9px 16px; font: inherit;
      color: #fff; background: #44444e; cursor: pointer; }
    button[type=submit] { background: #426ac1; }
  </style></head><body><main><h1>]] .. title .. [[</h1><form id="prompt">
    <label for="value">]] .. message .. [[</label><input id="value" type="text" autofocus>
    <div class="actions"><button type="button" id="cancel">]] .. cancel ..
    [[</button><button type="submit">]] .. submit .. [[</button></div></form></main>
    <script>
      const form = document.getElementById('prompt');
      const field = document.getElementById('value');
      form.addEventListener('submit', function(event) {
        event.preventDefault();
        webkit.messageHandlers.hsPrompt.postMessage({action: 'submit', text: field.value});
      });
      document.getElementById('cancel').addEventListener('click', function() {
        webkit.messageHandlers.hsPrompt.postMessage({action: 'cancel'});
      });
      field.focus();
    </script></body></html>]]
end

function M.request(options, callback)
  if current then return false end
  options = options or {}
  local form = { active = true, focused = false, monitorActive = false, callback = callback }
  local frame = screenFrame()
  if not frame or not hs.webview or not hs.webview.usercontent
      or type(hs.webview.usercontent.new) ~= "function"
      or type(hs.webview.new) ~= "function"
      or not hs.eventtap or type(hs.eventtap.new) ~= "function"
      or not hs.eventtap.event or not hs.eventtap.event.types then return fail(form) end
  local controllerOK, controller = pcall(hs.webview.usercontent.new, "hsPrompt")
  if not controllerOK or not controller then return fail(form) end
  if not call(controller, "setCallback", function(message) handleMessage(form, message) end) then
    return fail(form)
  end
  local width, height = 560, 260
  local viewFrame = {
    x = frame.x + (frame.w - width) / 2,
    y = frame.y + (frame.h - height) / 2,
    w = width, h = height,
  }
  local viewOK, view = pcall(hs.webview.new, viewFrame, {}, controller)
  if not viewOK or not view then return fail(form) end
  form.view = view
  local configured = call(view, "windowStyle", { "titled", "closable" })
    and call(view, "windowTitle", options.title or "Input")
    and call(view, "level", hs.drawing.windowLevels.floating)
    and call(view, "allowTextEntry", true)
    and call(view, "allowGestures", false)
    and call(view, "transparent", true)
    and call(view, "shadow", true)
    and call(view, "closeOnEscape", true)
    and call(view, "windowCallback", function(action, webview, focused)
      onWindow(form, action, focused == nil and webview or focused)
    end)
  if not configured then return fail(form) end
  -- Optional on older Hammerspoon builds; when available this runs after the
  -- HTML has loaded, which avoids showing a title bar before the page surface.
  form.waitsForNavigation = call(view, "navigationCallback", function(action)
    handleNavigation(form, action)
  end)
  local tapOK, tap = pcall(hs.eventtap.new, { hs.eventtap.event.types.keyDown },
    function(event) return handleKey(form, event) end)
  if not tapOK or not tap then return fail(form) end
  form.tap = tap
  current = form
  -- Load the page before displaying the native window. If the navigation
  -- callback is unavailable, the native window is shown as a compatibility
  -- fallback after the HTML has been accepted.
  if not call(view, "html", html(options)) then return fail(form) end
  if not form.waitsForNavigation or form.navigationFinished then showView(form) end
  return true
end

function M.close()
  if not current then return false end
  return finish(current, { status = "cancelled" })
end

function M.stop()
  return M.close()
end

return M
