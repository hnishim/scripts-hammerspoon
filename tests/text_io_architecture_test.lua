local function readFile(path)
  local handle = assert(io.open(path, "r"), "missing required source: " .. path)
  local contents = assert(handle:read("*a"))
  handle:close()
  return contents
end

local function assertContains(contents, needle, message)
  assert(contents:find(needle, 1, true), message .. ": missing " .. needle)
end

local function assertNotContains(contents, needle, message)
  assert(not contents:find(needle, 1, true), message .. ": unexpected " .. needle)
end

local urlSource = readFile("actions/url_commands.lua")
local aiSource = readFile("actions/ai_commands.lua")
readFile("components/text_io.lua")
readFile("components/text_prompt.lua")

-- Consumers must enter selection I/O through one public component rather than owning AX/copy branches.
assertContains(urlSource, 'require("components.text_io")', "URL command uses shared text I/O")
assertContains(aiSource, 'require("components.text_io")', "AI command uses shared text I/O")
assertNotContains(urlSource, "hs.uielement", "URL command must not own Accessibility selection acquisition")
assertNotContains(aiSource, "hs.uielement", "AI command must not own Accessibility selection acquisition")
assertNotContains(aiSource, "hs.eventtap.keyStroke", "AI command must not own Command-C selection fallback")

-- Prompting is a separate shared component; selection acquisition itself never owns prompt policy.
assertContains(urlSource, 'require("components.text_prompt")', "URL command uses shared prompt component")
assertContains(aiSource, 'require("components.text_prompt")', "AI display uses shared prompt component")
assertNotContains(urlSource, "hs.dialog.textPrompt", "URL command must not own prompt API")
assertNotContains(aiSource, "hs.dialog.textPrompt", "AI command must not own prompt API")

-- PowerPoint and the generic replacement helper are implementation details of the common I/O boundary.
assertNotContains(aiSource, 'require("components.powerpoint_selection")', "AI command must not own PowerPoint selection backend")
assertNotContains(aiSource, "replacement-engine", "AI command must not own generic replacement helper path")

print("text_io_architecture_test: ok")
