local realIoOpen = io.open
local home = os.getenv("HOME") or ""
local raycastRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast"

local virtualFiles = {
  ["/usr/bin/osascript"] = "",
  [raycastRoot .. "/two-panes-finder.applescript"] = "",
  [raycastRoot .. "/./two-panes-finder.applescript"] = "",
  [raycastRoot .. "/title-case-chicago.sh"] = "SCRIPT_DIR/title-case-chicago.py\n",
}

io.open = function(path, mode)
  local contents = virtualFiles[path]
  if contents ~= nil and (mode == nil or mode == "r") then
    return {
      read = function(_, format)
        assert(format == "*a", "CI file fixture only supports full reads")
        return contents
      end,
      close = function() end,
    }
  end
  return realIoOpen(path, mode)
end

local ok, err = pcall(dofile, "tests/utility_command_test.lua")
io.open = realIoOpen
if not ok then error(err, 0) end
