package.path = "./?.lua;./?/init.lua;" .. package.path

local config = require("hotkeys_config")
local home = os.getenv("HOME") or ""
local commandsRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/commands/"
local legacyRaycastRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast/"

local utilityCount = 0
local titleCaseSeen = false

for _, binding in ipairs(config) do
  local action = binding.action
  if action and action.type == "utility" and action.scriptPath then
    utilityCount = utilityCount + 1
    assert(action.scriptPath:sub(1, #commandsRoot) == commandsRoot,
      "utility script path must use the commands root: " .. tostring(action.scriptPath))
    assert(action.scriptPath:sub(1, #legacyRaycastRoot) ~= legacyRaycastRoot,
      "utility script path must not use the legacy Raycast root: " .. tostring(action.scriptPath))
    if action.scriptPath == commandsRoot .. "title-case-chicago.sh" then
      titleCaseSeen = true
    end
  end
end

assert(utilityCount > 0, "at least one external utility script binding must remain covered")
assert(titleCaseSeen, "Chicago Title Case must resolve from the commands root while HIR-89 remains incomplete")

print("commands path contract test passed")
