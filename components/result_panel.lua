local M = {}

local currentPanel

local function htmlEscape(value)
  return value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    :gsub('"', "&quot;"):gsub("'", "&#39;"):gsub("\n", "<br>")
end

local function invoke(resource, method, ...)
  if not resource or type(resource[method]) ~= "function" then return false end
  local ok, result = pcall(resource[method], resource, ...)
  return ok and result ~= false
end

local function invokeChain(resource, method, ...)
  if not resource or type(resource[method]) ~= "function" then return false end
  local ok, result = pcall(resource[method], resource, ...)
  return ok and result ~= nil and result ~= false
end

local function stopMonitor(panel)
  if not panel.monitorActive then return true end
  panel.monitorActive = false
  local stopped = invoke(panel.tap, "stop")
  if not stopped then panel.monitorStopOK = false end
  return stopped
end

local function deleteMonitor(panel)
  if panel.tapDeleted then return panel.tapDeleteOK end
  panel.tapDeleted = true
  local deleted = invoke(panel.tap, "delete")
  panel.tapDeleteOK = deleted
  return deleted
end

local function deleteView(panel)
  if panel.viewDeleted then return panel.viewDeleteOK end
  panel.viewDeleted = true
  local deleted = invoke(panel.view, "delete")
  panel.viewDeleteOK = deleted
  return deleted
end

local function cleanup(panel)
  if panel.cleaned then return panel.cleanupOK end
  panel.cleaned = true
  panel.active = false
  if currentPanel == panel then currentPanel = nil end
  panel.content = nil

  stopMonitor(panel)
  deleteMonitor(panel)
  deleteView(panel)
  panel.cleanupOK = panel.monitorStopOK and panel.tapDeleteOK and panel.viewDeleteOK
  return panel.cleanupOK
end

local function validFlags(event)
  local ok, flags = pcall(event.getFlags, event)
  if not ok or type(flags) ~= "table" or not flags.cmd then return false end
  for flag in pairs(flags) do
    if flag ~= "cmd" then return false end
  end
  return true
end

local function handleKey(panel, event)
  if currentPanel ~= panel or not panel.active or not panel.monitorActive then return false end
  if not event or type(event.getKeyCode) ~= "function" or not validFlags(event) then return false end
  local keyOK, keyCode = pcall(event.getKeyCode, event)
  if not keyOK then return false end

  if keyCode == 13 then
    return cleanup(panel)
  end
  if keyCode ~= 8 then return false end

  if not hs.pasteboard or type(hs.pasteboard.setContents) ~= "function" then return false end
  local ok, result = pcall(hs.pasteboard.setContents, panel.content)
  return ok and result ~= false
end

local function windowCallback(panel, action, value)
  if currentPanel ~= panel or not panel.active then return end
  if action == "focusChange" then
    if value == true then
      if panel.monitorActive then return end
      local started = invoke(panel.tap, "start")
      if started then panel.monitorActive = true end
    else
      stopMonitor(panel)
    end
  elseif action == "closing" then
    cleanup(panel)
  end
end

local function screenFrame()
  if not hs.screen or type(hs.screen.mainScreen) ~= "function" then return false end
  local screenOK, screen = pcall(hs.screen.mainScreen)
  if not screenOK or not screen or type(screen.frame) ~= "function" then return false end
  local frameOK, frame = pcall(screen.frame, screen)
  if not frameOK or type(frame) ~= "table" then return false end
  return frame
end

local function createView(frame, panel, html)
  if not hs.webview or type(hs.webview.new) ~= "function" then return false end
  local newOK, view = pcall(hs.webview.new, frame)
  if not newOK or not view then return false end
  panel.view = view

  local configured = invokeChain(view, "windowStyle", { "titled", "closable", "resizable" })
    and invokeChain(view, "windowTitle", "Gemini result")
    and invokeChain(view, "level", hs.drawing.windowLevels.floating)
    and invokeChain(view, "allowGestures", false)
    and invokeChain(view, "allowTextEntry", true)
    and invokeChain(view, "closeOnEscape", true)
    and invokeChain(view, "shadow", true)
    and invokeChain(view, "windowCallback", function(action, webview, focused)
      -- Hammerspoon passes (action, webview, focused). Keep the two-argument
      -- callback shape accepted by the component tests for compatibility.
      windowCallback(panel, action, focused == nil and webview or focused)
    end)
    and invokeChain(view, "html", html)
    and invokeChain(view, "show")
  return configured
end

function M.show(content)
  if type(content) ~= "string" or content == "" then return false end
  if currentPanel then cleanup(currentPanel) end

  local frame = screenFrame()
  if not frame then return false end
  local width, height = 760, 540
  local viewFrame = {
    x = frame.x + (frame.w - width) / 2,
    y = frame.y + (frame.h - height) / 2,
    w = width,
    h = height,
  }
  local panel = {
    active = true,
    content = content,
    monitorActive = false,
    monitorStopOK = true,
    tapDeleteOK = true,
    viewDeleteOK = true,
  }
  local html = [[<!doctype html><html lang="ja"><head><meta charset="utf-8"><style>
    html, body { background: #1e1e22; color: #f5f5f7; margin: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
    main { box-sizing: border-box; padding: 28px; white-space: normal; line-height: 1.65; }
    .result { font-size: 17px; overflow-wrap: anywhere; }
  </style></head><body><main><div class="result">]] .. htmlEscape(content) .. [[</div></main></body></html>]]

  if not createView(viewFrame, panel, html) then
    deleteView(panel)
    return false
  end

  if not hs.eventtap or not hs.eventtap.event or not hs.eventtap.event.types
      or type(hs.eventtap.new) ~= "function" then
    deleteView(panel)
    return false
  end
  local tapOK, tap = pcall(hs.eventtap.new, { hs.eventtap.event.types.keyDown }, function(event)
    return handleKey(panel, event)
  end)
  if not tapOK or not tap then
    deleteView(panel)
    return false
  end
  panel.tap = tap
  currentPanel = panel
  return true
end

function M.close()
  if not currentPanel then return false end
  return cleanup(currentPanel)
end

function M.stop()
  if not currentPanel then return false end
  return cleanup(currentPanel)
end

return M
