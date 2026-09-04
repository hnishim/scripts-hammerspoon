local alerts = {}
local timers = 0
local writes = 0
local actions = {}
local conflict = false
local expectedURL = "file://localhost/Users/cursor/project/delayed.lua"
local pasteboard = {
  contents = "before",
  changeCount = 1,
  types = { { "public.utf8-plain-text" } },
  data = { ["public.utf8-plain-text"] = "before" },
}

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message,
    tostring(expected), tostring(actual)))
end

local function setClipboard(value)
  pasteboard.contents = value
  pasteboard.changeCount = pasteboard.changeCount + 1
  pasteboard.types = { { "public.utf8-plain-text" } }
  pasteboard.data = { ["public.utf8-plain-text"] = value }
end

local function element(attributes)
  local item = {}
  function item:attributeValue(name)
    if name == "AXChildren" then return {} end
    return attributes[name]
  end
  function item:performAction(name)
    actions[#actions + 1] = name
    return false
  end
  return item
end

local window = element({
  AXRole = "AXWindow",
  AXDocument = "file://localhost/Users/cursor/project/editor.lua",
})
local appElement = element({ AXFocusedWindow = window, AXMainWindow = window })
local explorerPane = element({ AXRole = "AXOutline", AXTitle = "Files Explorer" })
local focused = element({ AXRole = "AXRow", AXURL = expectedURL, AXParent = explorerPane })

_G.hs = {
  alert = {
    show = function(message) alerts[#alerts + 1] = message end,
  },
  application = {
    frontmostApplication = function()
      return {
        name = function() return "Cursor" end,
        pid = function() return 123 end,
      }
    end,
  },
  axuielement = {
    systemWideElement = function()
      return {
        attributeValue = function(_, name)
          assertEqual(name, "AXFocusedUIElement", "Accessibility focus query")
          if conflict then
            conflict = false
            setClipboard("/Users/external/important.txt")
          end
          return focused
        end,
      }
    end,
    applicationElement = function(pid)
      assertEqual(pid, 123, "Cursor application PID")
      return appElement
    end,
  },
  timer = {
    doAfter = function()
      timers = timers + 1
      error("direct Cursor path must not schedule a timer")
    end,
  },
  pasteboard = {
    allContentTypes = function() return pasteboard.types end,
    readAllData = function() return pasteboard.data end,
    getContents = function() return pasteboard.contents end,
    changeCount = function() return pasteboard.changeCount end,
    setContents = function(value)
      writes = writes + 1
      setClipboard(value)
      return true
    end,
    writeAllData = function(data)
      writes = writes + 1
      pasteboard.data = data
      pasteboard.contents = data["public.utf8-plain-text"]
      pasteboard.changeCount = pasteboard.changeCount + 1
      return true
    end,
  },
}

package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["components.hud"] = function()
  return { showTransient = function() return true end }
end

local action = require("actions.file_name_copy")

-- The former delayed AXShowMenu route is intentionally gone. A direct AXURL
-- read succeeds synchronously, without menus, timers, or a full-path value.
assertEqual(action.run(), true, "Cursor Explorer direct operation succeeds")
assertEqual(pasteboard.contents, "delayed.lua", "direct path is basename-converted")
assertEqual(timers, 0, "direct path does not schedule a delayed callback")
assertEqual(writes, 1, "direct path writes once")
assertEqual(#actions, 0, "direct path performs no AX menu action")
assertEqual(#alerts, 0, "direct path has no alert")

-- An external writer between snapshot and final write wins the race.
action.stop()
pasteboard.contents = "before"
pasteboard.changeCount = 1
pasteboard.types = { { "public.utf8-plain-text" } }
pasteboard.data = { ["public.utf8-plain-text"] = "before" }
actions = {}
writes = 0
alerts = {}
conflict = true
assertEqual(action.run(), false, "direct Cursor conflict is rejected")
assertEqual(pasteboard.contents, "/Users/external/important.txt",
  "direct Cursor conflict preserves current clipboard")
assertEqual(writes, 0, "direct Cursor conflict does not write or restore")
assertEqual(#actions, 0, "direct Cursor conflict performs no AX menu action")
assertEqual(#alerts, 1, "direct Cursor conflict reports one alert")
assertEqual(alerts[1], "クリップボードの競合を検出したため、復元せず終了しました。",
  "direct Cursor conflict alert")

print("file_name_copy_delayed_conflict_test: PASS")
