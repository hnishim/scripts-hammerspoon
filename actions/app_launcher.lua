local hud = require("components.hud")

local M = {}

M.modifiers = { "cmd", "ctrl", "alt", "shift" }

M.keys = {
  "a",
  "b",
  "c",
  "d",
  "e",
  "f",
  "i",
  "j",
  "k",
  "m",
  "n",
  "p",
  "r",
  "s",
  "t",
  "w",
  "x",
  "z",
}

M.keyToApp = {
  a = "Microsoft Teams",
  b = "Arc",
  c = "Ferdium",
  d = "Cogito",
  e = "Cursor",
  f = "Finder",
  i = "ChatGPT",
  j = "Dictionaries",
  k = "Linear",
  m = "Meru",
  n = "Notion",
  p = "Microsoft PowerPoint",
  r = "Reminders",
  s = "Slack",
  t = "Warp",
  w = "1Password",
  x = "Microsoft Excel",
  z = "zoom.us",
}

M.allowedApps = {
  "Microsoft Teams",
  "Arc",
  "Ferdium",
  "Cogito",
  "Cursor",
  "Finder",
  "ChatGPT",
  "Dictionaries",
  "Linear",
  "Meru",
  "Notion",
  "Microsoft PowerPoint",
  "Reminders",
  "Slack",
  "Warp",
  "1Password",
  "Microsoft Excel",
  "zoom.us",
}

local allowedAppSet = {}
for _, app in ipairs(M.allowedApps) do
  allowedAppSet[app] = true
end

local function showError()
  if hs.alert and hs.alert.show then
    pcall(hs.alert.show, "コマンドを実行できませんでした。", 2)
  end
end

function M.launch(app)
  if type(app) ~= "string" or app == "" or not allowedAppSet[app] then return end

  local launchAlertID = hud.showTransient("Launching " .. app .. "...", 2)
  local ok, launched = pcall(function()
    return hs.application.launchOrFocus(app)
  end)
  if launchAlertID then hud.closeTransient(launchAlertID) end
  if not ok or launched == false then showError() end
end

return M
