local filters, canvases = {}, {}

local function same(actual, expected, label)
  assert(actual == expected, string.format("%s: expected %s, got %s",
    label, tostring(expected), tostring(actual)))
end

_G.hs = {
  window = {
    filter = {
      windowFocused = "windowFocused",
      new = function(_)
        local filter = { active = false }
        function filter:subscribe(event, callback, immediate)
          same(event, hs.window.filter.windowFocused, "subscribe to focus changes")
          assert(immediate ~= true, "initial focus must not trigger a flash")
          self.callback = callback
          self.active = true
          return self
        end
        function filter:unsubscribeAll() self.active = false return self end
        function filter:unsubscribe() self.active = false return self end
        function filter:pause() self.active = false return self end
        function filter:delete() self.active = false return self end
        filters[#filters + 1] = filter
        return filter
      end,
    },
  },
  canvas = {
    new = function(frame)
      local canvas = { frame = frame, elements = {}, shown = false, deleted = false }
      function canvas:appendElements(...)
        for _, element in ipairs({...}) do
          self.elements[#self.elements + 1] = element
        end
        return self
      end
      function canvas:replaceElements(...)
        self.elements = {...}
        return self
      end
      function canvas:show()
        self.shown = true
        return self
      end
      function canvas:delete(fade)
        self.deleted = true
        self.fade = fade or 0
      end
      function canvas:hide(fade)
        self.hidden = true
        self.fade = fade or 0
        return self
      end
      function canvas:clickActivating(flag)
        self.clickActivatingValue = flag
        return self
      end
      function canvas:mouseCallback(callback)
        self.mouseCallbackValue = callback
        return self
      end
      function canvas:level(value) self.levelValue = value return self end
      function canvas:behaviorAsLabels(value) self.behaviorValue = value return self end
      function canvas:bringToFront() return self end
      setmetatable(canvas, {
        __newindex = function(t, key, value)
          if type(key) == "number" then t.elements[key] = value
          else rawset(t, key, value) end
        end,
      })
      canvases[#canvases + 1] = canvas
      return canvas
    end,
  },
}

local function window(id, frame)
  return {
    id = function() return id end,
    frame = function() return frame end,
    isStandard = function() return true end,
    focus = function() error("flash must not take keyboard focus") end,
  }
end

local function focused(filter, target)
  if filter.active then filter.callback(target, "Example", hs.window.filter.windowFocused) end
end

package.path = "./?.lua;" .. package.path
package.loaded.focus_flash = nil
local flash = require("focus_flash")
assert(type(flash.start) == "function" and type(flash.stop) == "function",
  "focus flash must expose start and stop")

flash.start()
same(#filters, 1, "one dedicated focus watcher")
same(#canvases, 0, "starting must not flash the already focused window")

local first = window(101, { x = 40, y = 60, w = 440, h = 320 })
focused(filters[1], first)
same(#canvases, 1, "focus creates exactly one overlay")
same(canvases[1].shown, true, "overlay is displayed")
same(canvases[1].hidden or canvases[1].deleted, true,
  "normal flash starts fading without another focus event")
assert(type(canvases[1].fade) == "number" and canvases[1].fade >= 0.20
  and canvases[1].fade <= 0.50,
  "normal flash must have finite short fading within the approved adjustment range")
same(canvases[1].frame.x, 40, "overlay follows window x coordinate")
same(canvases[1].frame.y, 60, "overlay follows window y coordinate")
same(canvases[1].frame.w, 440, "overlay follows window width")
same(canvases[1].frame.h, 320, "overlay follows window height")
local shape = canvases[1].elements[1]
assert(shape and shape.type == "rectangle" and shape.action == "fill",
  "overlay is a filled rectangle, not an outline")
assert(shape.roundedRectRadii and shape.roundedRectRadii.xRadius == 20
  and shape.roundedRectRadii.yRadius == 20, "initial corner radius is 20pt")
local function checkFlashColor(color)
  assert(type(color) == "table", "flash must use an explicit RGB fill color")
  for _, channel in ipairs({ "red", "green", "blue" }) do
    assert(type(color[channel]) == "number" and color[channel] >= 0
      and color[channel] <= 1, "flash RGB channels must be in the range 0..1")
  end
  assert(type(color.alpha) == "number" and color.alpha >= 0.20
    and color.alpha <= 0.50, "flash opacity must be within the approved adjustment range")
  assert(color.blue > color.green and color.green > color.red and color.red > 0,
    "flash must be a pale-blue overlay that brightens a dark background")
  local whiteContrast = math.max(
    (1 - color.red) * color.alpha,
    (1 - color.green) * color.alpha,
    (1 - color.blue) * color.alpha)
  assert(whiteContrast >= 0.10,
    "flash must produce at least 0.10 composite channel contrast on a white background")
end
checkFlashColor(shape.fillColor)
assert(canvases[1].mouseCallbackValue == nil, "overlay must not consume mouse events")
assert(canvases[1].clickActivatingValue ~= true, "overlay must not activate Hammerspoon")

focused(filters[1], window(101, { x = 40, y = 60, w = 440, h = 320 }))
same(#canvases, 1, "duplicate focus of the same window does not flash again")

local second = window(102, { x = 700, y = 70, w = 500, h = 350 })
focused(filters[1], second)
same(#canvases, 2, "another window creates a new overlay")
same(canvases[1].deleted, true, "previous overlay is removed on quick switching")
same(canvases[2].shown, true, "new window is highlighted")
same(canvases[2].hidden or canvases[2].deleted, true,
  "each normal flash starts fading without another focus event")
assert(type(canvases[2].fade) == "number" and canvases[2].fade >= 0.20
  and canvases[2].fade <= 0.50,
  "each normal flash must have finite short fading within the approved adjustment range")
checkFlashColor(canvases[2].elements[1].fillColor)

focused(filters[1], nil)
focused(filters[1], window(103, { x = 0, y = 0, w = 0, h = 100 }))
local special = window(104, { x = 0, y = 0, w = 300, h = 200 })
special.isStandard = function() return false end
focused(filters[1], special)
same(#canvases, 2, "missing, invalid, or nonstandard windows never create overlays")

flash.start()
same(#filters, 2, "restart creates one replacement watcher")
same(filters[1].active, false, "restart detaches the previous watcher")
same(canvases[2].deleted, true, "restart removes the previous overlay")
same(#canvases, 2, "restart does not flash an existing focus")
focused(filters[1], first)
same(#canvases, 2, "old watcher cannot trigger a flash")
focused(filters[2], first)
same(#canvases, 3, "new watcher handles focus changes")

flash.stop()
same(filters[2].active, false, "stop detaches focus watcher")
same(canvases[3].deleted, true, "stop removes the current overlay")
focused(filters[2], second)
same(#canvases, 3, "no flash after stop")
flash.stop()

print("focus_flash_test: ok")
