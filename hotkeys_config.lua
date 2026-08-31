local home = os.getenv("HOME") or ""
local promptDir = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/prompts/ai-commands/"
local raycastRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast/"

return {
  -- ==============================
  -- Hyper key (Cmd+Ctrl+Opt+Shift)
  -- ==============================

  -- Application launchers
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "a", action = { type = "app", app = "Microsoft Teams" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "b", action = { type = "app", app = "Arc" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "c", action = { type = "app", app = "Ferdium" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "d", action = { type = "app", app = "Cogito" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "e", action = { type = "app", app = "Cursor" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "f", action = { type = "app", app = "Finder" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "i", action = { type = "app", app = "ChatGPT" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "j", action = { type = "app", app = "Dictionaries" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "k", action = { type = "app", app = "Linear" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "m", action = { type = "app", app = "Meru" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "n", action = { type = "app", app = "Notion" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "p", action = { type = "app", app = "Microsoft PowerPoint" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "r", action = { type = "app", app = "Reminders" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "s", action = { type = "app", app = "Slack" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "t", action = { type = "app", app = "Warp" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "w", action = { type = "app", app = "1Password" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "x", action = { type = "app", app = "Microsoft Excel" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "z", action = { type = "app", app = "zoom.us" } },

  -- ==============================
  -- Cmd+Opt+Shift
  -- ==============================

  -- AI commands
  {
    modifiers = { "cmd", "alt", "shift" },
    key = "B",
    action = {
      type = "ai",
      promptPath = promptDir .. "bio-ai_expert.md",
      model = "gemini-flash-lite-latest",
      mode = "display",
    },
  },
  {
    modifiers = { "cmd", "alt", "shift" },
    key = "R",
    action = {
      type = "ai",
      promptPath = promptDir .. "review-text_compact.md",
      model = "gemini-flash-lite-latest",
      mode = "replace",
    },
  },
  {
    modifiers = { "cmd", "alt", "shift" },
    key = "T",
    action = {
      type = "ai",
      promptPath = promptDir .. "translate.md",
      model = "gemini-flash-lite-latest",
      mode = "replace",
    },
  },

  -- URL commands
  { modifiers = { "cmd", "alt", "shift" }, key = "G", action = { type = "url", command = "google" } },
  { modifiers = { "cmd", "alt", "shift" }, key = "J", action = { type = "url", command = "dictionary" } },

  -- Utility scripts
  {
    modifiers = { "cmd", "alt", "shift" },
    key = "f",
    action = {
      type = "utility",
      executablePath = "/usr/bin/osascript",
      scriptPath = raycastRoot .. "two-panes-finder.applescript",
    },
  },
  {
    modifiers = { "cmd", "alt", "shift" },
    key = "c",
    action = {
      type = "utility",
      executablePath = "/bin/bash",
      scriptPath = raycastRoot .. "title-case-chicago.sh",
    },
  },

  -- ==============================
  -- Cmd+Ctrl
  -- ==============================

  -- Window management
  { modifiers = { "cmd", "ctrl" }, key = "t", action = { type = "window", command = "bottom" } },
  { modifiers = { "cmd", "ctrl" }, key = "c", action = { type = "window", command = "center" } },
  { modifiers = { "cmd", "ctrl" }, key = "g", action = { type = "window", command = "left" } },
  { modifiers = { "cmd", "ctrl" }, key = "r", action = { type = "window", command = "right" } },
  { modifiers = { "cmd", "ctrl" }, key = "n", action = { type = "window", command = "top" } },
  { modifiers = { "cmd", "ctrl" }, key = "f", action = { type = "window", command = "full" } },

  -- Previous display
  { modifiers = { "cmd", "ctrl" }, key = "P", action = { type = "window", command = "previous-display" } },
}
