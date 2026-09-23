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
same(canvases[1].frame.x, 40, "overlay follows window x coordinate")
same(canvases[1].frame.y, 60, "overlay follows window y coordinate")
same(canvases[1].frame.w, 440, "overlay follows window width")
same(canvases[1].frame.h, 320, "overlay follows window height")
local shape = canvases[1].elements[1]
assert(shape and shape.type == "rectangle" and shape.action == "fill",
  "overlay is a filled rectangle, not an outline")
assert(shape.roundedRectRadii and shape.roundedRectRadii.xRadius == 20
  and shape.roundedRectRadii.yRadius == 20, "initial corner radius is 20pt")
assert(shape.fillColor and math.abs(shape.fillColor.alpha - 0.12) < 0.001,
  "initial overlay opacity is 12 percent")
assert(canvases[1].mouseCallbackValue == nil, "overlay must not consume mouse events")
assert(canvases[1].clickActivatingValue ~= true, "overlay must not activate Hammerspoon")

focused(filters[1], window(101, { x = 40, y = 60, w = 440, h = 320 }))
same(#canvases, 1, "duplicate focus of the same window does not flash again")

local second = window(102, { x = 700, y = 70, w = 500, h = 350 })
focused(filters[1], second)
same(#canvases, 2, "another window creates a new overlay")
same(canvases[1].deleted, true, "previous overlay is removed on quick switching")
same(canvases[2].shown, true, "new window is highlighted")
assert(canvases[2].fade == nil or math.abs(canvases[2].fade - 0.2) < 0.001,
  "a normal flash fades out in approximately 200ms")

focused(filters[1], nil)
focused(filters[1], window(103, { x = 0, y = 0, w = 0, h = 100 }))
same(#canvases, 2, "missing or invalid windows never create overlays")

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
