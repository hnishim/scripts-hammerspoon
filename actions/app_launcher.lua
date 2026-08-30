local hud = require("components.hud")

local M = {}

local function showError()
  if hs.alert and hs.alert.show then
    pcall(hs.alert.show, "コマンドを実行できませんでした。", 2)
  end
end

function M.run(app)
  if type(app) ~= "string" or app == "" then return false end

  hud.showTransient("Launching " .. app .. "...", 2)
  local ok, launched = pcall(function()
    return hs.application.launchOrFocus(app)
  end)
  if not ok or launched == false then showError() end
  return ok and launched ~= false
end

return M
