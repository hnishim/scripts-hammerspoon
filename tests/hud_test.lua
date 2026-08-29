local alerts = {}
local closed = {}
local nextID = 0
local showFailure = false

_G.hs = {
  alert = {
    show = function(message, style, screen, seconds)
      if showFailure then error("alert show failure") end
      nextID = nextID + 1
      alerts[#alerts + 1] = {
        id = nextID,
        message = message,
        style = style,
        screen = screen,
        seconds = seconds,
      }
      return nextID
    end,
    closeSpecific = function(id)
      closed[#closed + 1] = id
    end,
  },
}

package.path = "./?.lua;" .. package.path
local hud = require("hud")

local function assertEqual(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

hud.show("任意の待機メッセージ")
local firstID = alerts[1].id
assertEqual(#alerts, 1, "show displays one HUD")
assertEqual(alerts[1].message, "任意の待機メッセージ", "show forwards arbitrary message")
assert(alerts[1].seconds ~= nil and type(alerts[1].seconds) ~= "number", "HUD uses an explicit persistent, non-numeric duration")
assertEqual(#closed, 0, "HUD remains visible before close")

hud.show("別の待機メッセージ")
local secondID = alerts[2].id
assertEqual(#alerts, 2, "re-entry updates the HUD without losing the new display")
assertEqual(#closed, 1, "re-entry closes the previous HUD")
assertEqual(closed[1], firstID, "re-entry closes only the previous display")

local unrelated = hs.alert.show("既存のエラー通知", nil, nil, 2)
local transientID = hud.showTransient("短時間の通知", 2)
assertEqual(#alerts, 4, "transient HUD adds an independent alert")
assertEqual(alerts[4].message, "短時間の通知", "transient HUD forwards the message")
assertEqual(alerts[4].seconds, 2, "transient HUD forwards the duration")
assertEqual(#closed, 1, "transient HUD does not close the persistent HUD")
hud.close()
assertEqual(#closed, 2, "explicit close closes the current HUD")
assertEqual(closed[2], secondID, "explicit close targets the current display")
assert(closed[2] ~= unrelated, "explicit close does not close an unrelated notification")
hud.closeTransient(transientID)
assertEqual(#closed, 3, "explicit transient close closes only the transient display")
assertEqual(closed[3], transientID, "transient close targets the transient display")
hud.close()
assertEqual(#closed, 3, "close is idempotent")

local closedBeforeShowFailure = #closed
showFailure = true
local showOK = pcall(hud.show, "表示API失敗")
assert(showOK, "show handles alert API failure without throwing")
hud.close()
assertEqual(#closed, closedBeforeShowFailure, "failed show leaves no close target")

print("hud_test: ok")
