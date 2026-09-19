package.path = "./?.lua;./?/init.lua;" .. package.path

local config = require("hotkeys_config")
local home = os.getenv("HOME") or ""
local commandsRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/commands/"
local legacyRaycastRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast/"

local titleCaseSeen = false

for _, binding in ipairs(config) do
  local action = binding.action
  if action and action.type == "utility" and action.scriptPath then
    assert(action.scriptPath:sub(1, #commandsRoot) == commandsRoot,
      "utility script path must use the commands root: " .. tostring(action.scriptPath))
    assert(action.scriptPath:sub(1, #legacyRaycastRoot) ~= legacyRaycastRoot,
      "utility script path must not use the legacy Raycast root: " .. tostring(action.scriptPath))
    if action.scriptPath == commandsRoot .. "title-case-chicago.sh" then
      titleCaseSeen = true
    end
  end
end

assert(not titleCaseSeen, "Chicago Title Case must not use the legacy Shell script")

print("commands path contract test passed")
