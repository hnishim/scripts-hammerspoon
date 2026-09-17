local M = {}

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.request(options)
  options = options or {}
  if type(hs) ~= "table" or type(hs.dialog) ~= "table" or type(hs.dialog.textPrompt) ~= "function" then
    return { status = "error" }
  end
  local title = options.title or "入力"
  local message = options.message or ""
  local submit = options.submit or "OK"
  local ok, button, value
  if options.cancel ~= nil then
    ok, button, value = pcall(hs.dialog.textPrompt, title, message, "", submit, options.cancel)
  else
    ok, button, value = pcall(hs.dialog.textPrompt, title, message, "", submit)
  end
  if not ok then return { status = "error" } end
  if button ~= submit then return { status = "cancelled" } end
  value = trim(value)
  if value == "" then return { status = "empty" } end
  return { status = "submitted", text = value }
end

return M
