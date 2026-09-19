-- Chicago owns only transformation and the session-bound write-back request.
-- Selection, target verification, clipboard and PowerPoint routing belong to text_io.
local textIO = require("components.text_io")
local converter = require("components.chicago_title_case")
local M = {}
local generation = 0

function M.stop()
  generation = generation + 1
  -- Do not stop the shared text_io backend: it may also serve another action.
  return true
end

function M.run()
  generation = generation + 1
  local current = generation
  return textIO.capture("replace", function(result)
    if current ~= generation or type(result) ~= "table" or result.status ~= "selected"
        or type(result.text) ~= "string" or result.text == ""
        or type(result.replace) ~= "function" then return end

    local ok, converted = pcall(converter.convert, result.text)
    if not ok or type(converted) ~= "string" or converted == ""
        or converted == result.text or current ~= generation then return end

    -- Do not retry or fall back to another write route on rejection, exception,
    -- or an unverified outcome: a replacement may already have been dispatched.
    pcall(result.replace, converted, function(_) end)
  end)
end

return M
