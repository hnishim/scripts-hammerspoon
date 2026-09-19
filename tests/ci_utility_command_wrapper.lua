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

package.preload["components.hud"] = function()
  return {
    showTransient = function(message, seconds)
      if _G.hs and hs.alert and type(hs.alert.show) == "function" then
        return hs.alert.show(message, seconds)
      end
      return nil
    end,
  }
end

local ok, err = pcall(dofile, "tests/utility_command_test.lua")
io.open = realIoOpen
package.preload["components.hud"] = nil
package.loaded["components.hud"] = nil
if not ok then error(err, 0) end
