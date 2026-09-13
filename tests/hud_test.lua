local canvases = {}
local timers = {}
local timerSequence = 0
local screenFrame = { x = 100, y = 50, w = 1200, h = 800 }
local canvasFailure = nil

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function assertNear(actual, expected, tolerance, message)
  assert(math.abs(actual - expected) <= tolerance,
    string.format("%s: expected %s +/- %s, got %s", message, tostring(expected), tostring(tolerance), tostring(actual)))
end

local function copyFrame(frame)
  return { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
end

local function makeCanvas(frame)
  if canvasFailure == "new" then return nil end

  local object = {
    frameValue = copyFrame(frame),
    elements = {},
    shown = false,
    deleted = false,
    levelValue = nil,
    behaviorValue = nil,
    wantsLayerValue = nil,
  }

  local function addElement(element, index)
    local slot = index or (#object.elements + 1)
    object.elements[slot] = element
    if type(element) == "table" and element.id ~= nil then
      rawset(object, element.id, element)
    end
  end

  function object:appendElements(...)
    for _, element in ipairs({ ... }) do addElement(element) end
    return self
  end

  function object:replaceElements(elements)
    self.elements = {}
    for key in pairs(self) do
      if type(key) == "string" and key:match("^element:") then self[key] = nil end
    end
    for index, element in ipairs(elements or {}) do addElement(element, index) end
    return self
  end

  function object:insertElement(element, index)
    if index then
      table.insert(self.elements, index, element)
    else
      self.elements[#self.elements + 1] = element
    end
    if type(element) == "table" and element.id ~= nil then rawset(self, element.id, element) end
    return self
  end

  function object:show()
    if canvasFailure == "show" then error("canvas show failure") end
    self.shown = true
    return self
  end

  function object:hide()
    self.shown = false
    return self
  end

  function object:delete()
    self.deleted = true
    self.shown = false
    return nil
  end

  function object:level(value)
    self.levelValue = value
    return self
  end

  function object:behavior(value)
    self.behaviorValue = value
    return self
  end

  function object:wantsLayer(value)
    self.wantsLayerValue = value
    return self
  end

  function object:rotateElement(id, degrees)
    local element = self[id]
    if element then element._rotation = (element._rotation or 0) + degrees end
    return self
  end

  setmetatable(object, {
    __newindex = function(target, key, value)
      if type(key) == "number" then
        addElement(value, key)
      else
        rawset(target, key, value)
      end
    end,
  })

  canvases[#canvases + 1] = object
  return object
end

local function makeTimer(kind, delay, callback)
  timerSequence = timerSequence + 1
  local timer = {
    id = timerSequence,
    kind = kind,
    delay = delay,
    callback = callback,
    stopped = false,
    fired = false,
  }
  function timer:stop() self.stopped = true end
  timers[#timers + 1] = timer
  return timer
end

_G.hs = {
  alert = {
    show = function()
      error("HUD implementation must not use hs.alert")
    end,
    closeSpecific = function()
      error("HUD implementation must not use hs.alert")
    end,
  },
  screen = {
    mainScreen = function()
      return {
        frame = function() return copyFrame(screenFrame) end,
      }
    end,
  },
  canvas = {
    new = makeCanvas,
    windowLevels = { floating = 3 },
  },
  timer = {
    doEvery = function(delay, callback) return makeTimer("every", delay, callback) end,
    doAfter = function(delay, callback) return makeTimer("after", delay, callback) end,
    stop = function(timer) timer:stop() end,
  },
}

package.path = "./?.lua;" .. package.path
package.loaded["components.hud"] = nil
local hud = require("components.hud")

local function liveTimers(kind)
  local result = {}
  for _, timer in ipairs(timers) do
    if not timer.stopped and not timer.fired and (kind == nil or timer.kind == kind) then
      result[#result + 1] = timer
    end
  end
  return result
end

local function findElement(canvas, id, elementType)
  if id ~= nil and type(canvas[id]) == "table" then return canvas[id] end
  for _, element in ipairs(canvas.elements) do
    if type(element) == "table"
        and (id == nil or element.id == id)
        and (elementType == nil or element.type == elementType) then
      return element
    end
  end
  return nil
end

local function backgroundElement(canvas)
  for _, element in ipairs(canvas.elements) do
    if type(element) == "table" and element.type == "rectangle" then return element end
  end
  return nil
end

local function textElement(canvas)
  for _, element in ipairs(canvas.elements) do
    if type(element) == "table" and element.type == "text" then return element end
  end
  return nil
end

local function spinnerSignature(canvas)
  local spinner = findElement(canvas, "spinner")
  if not spinner then
    for _, element in ipairs(canvas.elements) do
      if type(element) == "table" and (element.type == "arc" or element.type == "ellipticalArc") then
        spinner = element
        break
      end
    end
  end
  assert(spinner, "persistent HUD must include a spinner/animated indicator")
  return table.concat({
    tostring(spinner.startAngle),
    tostring(spinner.endAngle),
    tostring(spinner._rotation),
  }, ":")
end

assertEqual(hud.show("Processing..."), true, "persistent HUD show succeeds")
assertEqual(#canvases, 1, "persistent HUD creates one canvas")
local persistent = canvases[1]
assert(persistent.shown, "persistent HUD is shown")
assert(not persistent.deleted, "persistent HUD remains alive before close")

local frame = persistent.frameValue
assert(frame.w > 0 and frame.h > 0, "HUD frame has positive size")
assert(frame.w < screenFrame.w and frame.h < screenFrame.h, "HUD is compact relative to screen")
assertNear(frame.x + frame.w / 2, screenFrame.x + screenFrame.w / 2, 2,
  "HUD is horizontally centered")
assertNear(frame.y + frame.h / 2, screenFrame.y + screenFrame.h * 0.75, 2,
  "HUD center is at 75 percent of screen height")

local background = assert(backgroundElement(persistent), "persistent HUD has a background")
assert(type(background.fillColor) == "table" and (background.fillColor.alpha or 1) < 1,
  "HUD background is translucent")
assert(type(background.roundedRectRadii) == "table"
    and (background.roundedRectRadii.xRadius or 0) > 0
    and (background.roundedRectRadii.yRadius or 0) > 0,
  "HUD background has rounded corners")
assert(background.withShadow == true, "HUD background has a shadow")

local persistentText = assert(textElement(persistent), "persistent HUD has text")
assertEqual(persistentText.text, "Processing...", "persistent HUD forwards message")
assert(type(persistentText.textSize) == "number" and persistentText.textSize > 0 and persistentText.textSize < 27,
  "HUD text is smaller than the hs.canvas default text size")
assert(persistentText.textFont == nil or persistentText.textFont == "",
  "HUD uses the system font instead of a bundled/custom font")

local animationTimers = liveTimers("every")
assertEqual(#animationTimers, 1, "persistent HUD starts one animation timer")
local beforeAnimation = spinnerSignature(persistent)
animationTimers[1].callback()
local afterAnimation = spinnerSignature(persistent)
assert(beforeAnimation ~= afterAnimation, "animation tick changes spinner presentation")

assertEqual(hud.show("Still processing..."), true, "persistent HUD supports re-entry")
assertEqual(#canvases, 2, "re-entry creates a replacement canvas")
assert(persistent.deleted, "re-entry deletes previous persistent canvas")
assert(animationTimers[1].stopped, "re-entry stops previous animation timer")
local replacement = canvases[2]
assert(replacement.shown and not replacement.deleted, "replacement HUD is shown")

local transientToken = hud.showTransient("Copied", 3)
assert(transientToken ~= nil and transientToken ~= false, "transient HUD returns a close token")
assertEqual(#canvases, 3, "transient HUD creates an independent canvas")
local transient = canvases[3]
assert(transient.shown and not transient.deleted, "transient HUD is shown")
assert(not replacement.deleted, "transient HUD does not close persistent HUD")
local transientBackground = assert(backgroundElement(transient), "transient HUD has a background")
local transientText = assert(textElement(transient), "transient HUD has text")
assertEqual(transientText.text, "Copied", "transient HUD forwards message")
assertEqual(transientText.textSize, textElement(replacement).textSize,
  "persistent and transient HUD use same text size")
assertEqual(transientBackground.roundedRectRadii.xRadius, backgroundElement(replacement).roundedRectRadii.xRadius,
  "persistent and transient HUD share corner radius")
assertEqual(transientBackground.fillColor.alpha, backgroundElement(replacement).fillColor.alpha,
  "persistent and transient HUD share background transparency")

local timeoutTimers = liveTimers("after")
assertEqual(#timeoutTimers, 1, "transient HUD starts one timeout timer")
assertEqual(timeoutTimers[1].delay, 3, "transient HUD uses requested duration")

hud.close()
assert(replacement.deleted, "close deletes current persistent HUD")
assertEqual(#liveTimers("every"), 0, "close stops persistent animation timer")
hud.close()
assertEqual(#liveTimers("every"), 0, "close is idempotent")

hud.closeTransient(transientToken)
assert(transient.deleted, "closeTransient deletes only target transient HUD")
assert(timeoutTimers[1].stopped, "closeTransient stops target timeout timer")
hud.closeTransient(transientToken)
assert(transient.deleted, "closeTransient is idempotent")

local timedToken = hud.showTransient("Timed", 1)
assert(timedToken ~= nil and timedToken ~= false, "second transient HUD returns token")
local timedCanvas = canvases[#canvases]
local currentTimeouts = liveTimers("after")
assertEqual(#currentTimeouts, 1, "second transient HUD has one live timeout")
currentTimeouts[1].fired = true
currentTimeouts[1].callback()
assert(timedCanvas.deleted, "transient timeout deletes its canvas")
hud.closeTransient(timedToken)
assert(timedCanvas.deleted, "explicit close after timeout is safe")

canvasFailure = "new"
assertEqual(hud.show("Failure"), false, "canvas creation failure is contained")
assertEqual(#liveTimers("every"), 0, "failed show leaves no animation timer")
canvasFailure = "show"
assertEqual(hud.show("Failure"), false, "canvas show failure is contained")
assertEqual(#liveTimers("every"), 0, "show failure leaves no animation timer")
canvasFailure = nil

print("hud_test: ok")
