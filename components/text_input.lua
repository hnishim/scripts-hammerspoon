local M = {}

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.acquireSelection()
  if not hs or not hs.uielement or type(hs.uielement.focusedElement) ~= "function" then
    return { status = "error", reason = "api_unavailable" }
  end

  local focusedOK, focused = pcall(hs.uielement.focusedElement)
  if not focusedOK then
    return { status = "error", reason = "focused_error" }
  end
  if focused == nil then
    return { status = "no_focused_element" }
  end
  if type(focused.selectedText) ~= "function" then
    return { status = "error", reason = "api_unavailable", element = focused }
  end

  local selectedOK, value = pcall(focused.selectedText, focused)
  if not selectedOK then
    return { status = "error", reason = "selection_error", element = focused }
  end
  if value == nil then
    return { status = "no_selection", element = focused }
  end
  if type(value) ~= "string" then
    return { status = "error", reason = "invalid_type", element = focused }
  end

  return { status = "selected", text = value, element = focused }
end

function M.prompt(options)
  options = options or {}
  if not hs or not hs.dialog or type(hs.dialog.textPrompt) ~= "function" then
    return { status = "error", reason = "api_unavailable" }
  end

  local ok, button, value
  if options.cancelButton ~= nil then
    ok, button, value = pcall(hs.dialog.textPrompt,
      options.title, options.message, options.defaultText or "", options.submitButton, options.cancelButton)
  else
    ok, button, value = pcall(hs.dialog.textPrompt,
      options.title, options.message, options.defaultText or "", options.submitButton)
  end
  if not ok then
    return { status = "error", reason = "prompt_error" }
  end
  if button ~= options.submitButton then
    return { status = "cancelled" }
  end

  value = trim(value)
  if value == "" then
    return { status = "empty" }
  end
  return { status = "submitted", text = value }
end

return M
