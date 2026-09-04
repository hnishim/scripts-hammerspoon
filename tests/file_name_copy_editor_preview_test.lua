local alerts = {}
local timers = {}
local axActions = {}
local writeValues = {}
local focusedAttributes = { AXRole = "AXTextArea" }
local windowAttributes = {
  AXRole = "AXWindow",
  AXDocument = "file:///Users/cursor/project/editor%20preview.lua",
}
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

local function element(attributes, children, action)
  local item = {}
  function item:attributeValue(name)
    if name == "AXChildren" then return children end
    return attributes[name]
  end
  function item:performAction(name)
    axActions[#axActions + 1] = name
    if action then return action(name) end
    return false
  end
  return item
end

local window = element(windowAttributes, {})
local appElement = element({ AXFocusedWindow = window }, {})
local focused = element(focusedAttributes, {})
local explorerPane = element({ AXRole = "AXOutline", AXTitle = "Files Explorer" }, {})

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
    doAfter = function(delay, callback)
      assertEqual(delay, 1.2, "Cursor wait")
      timers[#timers + 1] = callback
      return { stop = function() end }
    end,
  },
  pasteboard = {
    allContentTypes = function() return pasteboard.types end,
    readAllData = function() return pasteboard.data end,
    getContents = function() return pasteboard.contents end,
    changeCount = function() return pasteboard.changeCount end,
    setContents = function(value)
      writeValues[#writeValues + 1] = value
      setClipboard(value)
      return true
    end,
    writeAllData = function(data)
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
assertEqual(action.run(), true, "Cursor Editor preview operation starts")
assertEqual(#timers, 0, "Cursor Editor preview operation does not schedule a timer")
assertEqual(#axActions, 0, "Cursor Editor preview performs no AX menu action")
assertEqual(#writeValues, 1, "Cursor Editor preview writes once")
assertEqual(writeValues[1], "editor preview.lua", "Cursor Editor preview writes only basename")
assertEqual(pasteboard.contents, "editor preview.lua",
  "Cursor Editor preview tab copies the Active File basename")
assertEqual(#alerts, 0, "Cursor Editor preview tab has no alert")

-- A Terminal-focused Cursor window is still an Active File route. It must not
-- require an editor role or open a context menu.
pasteboard.contents = "before"
pasteboard.changeCount = 1
pasteboard.types = { { "public.utf8-plain-text" } }
pasteboard.data = { ["public.utf8-plain-text"] = "before" }
writeValues = {}
windowAttributes.AXDocument = "file:///Users/cursor/project/terminal%20target.sh"
focusedAttributes.AXRole = "AXTextField"
assertEqual(action.run(), true, "Cursor Terminal operation starts")
assertEqual(#timers, 0, "Cursor Terminal operation does not schedule a timer")
assertEqual(#axActions, 0, "Cursor Terminal performs no AX menu action")
assertEqual(#writeValues, 1, "Cursor Terminal writes once")
assertEqual(writeValues[1], "terminal target.sh", "Cursor Terminal writes only basename")
assertEqual(pasteboard.contents, "terminal target.sh",
  "Cursor Terminal copies the Active File basename")
assertEqual(#alerts, 0, "Cursor Terminal has no alert")

-- Explorer is the only selection-specific route. Its AXURL is converted
-- directly, so the full path never becomes the final clipboard value.
pasteboard.contents = "before"
pasteboard.changeCount = 1
pasteboard.types = { { "public.utf8-plain-text" } }
pasteboard.data = { ["public.utf8-plain-text"] = "before" }
writeValues = {}
focusedAttributes.AXRole = "AXRow"
focusedAttributes.AXURL = "file:///Users/cursor/project/lib/module.lua"
focusedAttributes.AXParent = explorerPane
assertEqual(action.run(), true, "Cursor Explorer operation starts")
assertEqual(#timers, 0, "Cursor Explorer operation does not schedule a timer")
assertEqual(#axActions, 0, "Cursor Explorer performs no AX menu action")
assertEqual(#writeValues, 1, "Cursor Explorer writes once")
assertEqual(writeValues[1], "module.lua", "Cursor Explorer writes only basename")
assertEqual(pasteboard.contents, "module.lua",
  "Cursor Explorer copies the selected basename")
assertEqual(#alerts, 0, "Cursor Explorer has no alert")

-- Cursor may expose the Explorer path on a descendant description instead of
-- AXURL on the focused row.
pasteboard.contents = "before"
pasteboard.changeCount = 1
pasteboard.types = { { "public.utf8-plain-text" } }
pasteboard.data = { ["public.utf8-plain-text"] = "before" }
writeValues = {}
focused = element({ AXRole = "AXRow", AXParent = explorerPane }, {
  element({ AXDescription = "~/cursor/project/desc-only.txt • Modified" }, {}),
})
focusedAttributes.AXURL = nil
assertEqual(action.run(), true, "Cursor Explorer descendant-path operation starts")
assertEqual(#timers, 0, "Cursor Explorer descendant-path operation does not schedule a timer")
assertEqual(#axActions, 0, "Cursor Explorer descendant path performs no AX menu action")
assertEqual(#writeValues, 1, "Cursor Explorer descendant path writes once")
assertEqual(writeValues[1], "desc-only.txt", "Cursor Explorer descendant path writes only basename")
assertEqual(pasteboard.contents, "desc-only.txt",
  "Cursor Explorer descendant path copies the selected basename")
assertEqual(#alerts, 0, "Cursor Explorer descendant path has no alert")

print("file_name_copy_editor_preview_test: PASS")
