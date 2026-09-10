local home = os.getenv("HOME") or ""
local promptDir = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/prompts/ai-commands/"
local raycastRoot = home .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/raycast/"

-- 複雑なアクションの事前定義
local actions = {
  {
    name = "bio-ai_expert",
    action = {
      type = "ai",
      promptPath = promptDir .. "bio-ai_expert.md",
      model = "gemini-flash-latest",
      model_failover = "gemini-flash-lite-latest",
      mode = "display",
    },
  },
  {
    name = "review-text_compact",
    action = {
      type = "ai",
      promptPath = promptDir .. "review-text_compact.md",
      model = "gemini-flash-latest",
      model_failover = "gemini-flash-lite-latest",
      mode = "replace",
    },
  },
  {
    name = "translate",
    action = {
      type = "ai",
      promptPath = promptDir .. "translate.md",
      model = "gemini-flash-lite-latest",
      mode = "replace",
    },
  },
  {
    name = "two-panes-finder",
    action = {
      type = "utility",
      executablePath = "/usr/bin/osascript",
      scriptPath = raycastRoot .. "two-panes-finder.applescript",
    },
  },
  {
    name = "title-case-chicago",
    action = {
      type = "utility",
      executablePath = "/bin/bash",
      scriptPath = raycastRoot .. "title-case-chicago.sh",
    },
  },
}

-- アクションを取得するヘルパー関数
local function getAction(name)
  for _, definition in ipairs(actions) do
    if definition.name == name then return definition.action end
  end
  error("unknown action: " .. tostring(name))
end

-- ホットキーの定義
return {
  -- ==============================
  -- Hyper key (Cmd+Ctrl+Opt+Shift): メインはApp Launcher
  -- ==============================

  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "a", action = { type = "app", app = "Microsoft Teams" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "b", action = { type = "app", app = "Arc" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "c", action = { type = "app", app = "Ferdium" } },
  -- d
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "e", action = { type = "app", app = "Cursor" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "f", action = { type = "app", app = "Finder" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "g", action = { type = "url", command = "google" } },
  -- h
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "i", action = { type = "app", app = "ChatGPT" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "j", action = { type = "app", app = "Dictionaries" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "k", action = { type = "app", app = "Linear" } },
  -- l
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "m", action = { type = "app", app = "Meru" } },
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "n", action = { type = "app", app = "Notion" } },
  -- o
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "p", action = { type = "app", app = "Microsoft PowerPoint" } },
  -- q
  -- r
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "s", action = { type = "app", app = "Slack" } },
  -- t
  -- u
  -- v
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "w", action = { type = "app", app = "1Password" } },
  -- y
  -- x
  { modifiers = { "cmd", "ctrl", "alt", "shift" }, key = "z", action = { type = "app", app = "zoom.us" } },

  -- ==============================
  -- Cmd+Opt+Shift: AIコマンド / スクリプトコマンド
  -- ==============================

  -- a
  { modifiers = { "cmd", "alt", "shift" }, key = "b", action = getAction("bio-ai_expert") },
  { modifiers = { "cmd", "alt", "shift" }, key = "c", action = getAction("title-case-chicago") },
  -- d
  -- e
  { modifiers = { "cmd", "alt", "shift" }, key = "f", action = getAction("two-panes-finder") },
  -- g グルーピング解除 (PowerPoint)
  -- h
  -- i
  { modifiers = { "cmd", "alt", "shift" }, key = "j", action = { type = "url", command = "dictionary" } },
  -- k
  -- l
  -- m
  -- n
  -- o
  -- p
  -- q
  { modifiers = { "cmd", "alt", "shift" }, key = "r", action = getAction("review-text_compact") },
  -- s
  { modifiers = { "cmd", "alt", "shift" }, key = "t", action = getAction("translate") },
  -- u
  -- v 書式なし貼り付け（PowerPoint, Word等）
  -- w
  -- x
  -- y
  -- z

  -- ==============================
  -- Cmd+Opt+Ctrl
  -- ==============================

  -- w 1Password Autofill @ 1Password

  -- ==============================
  -- Cmd+Ctrl: ウィンドウ操作 / スクリーンショット（Snapzy）
  -- ==============================

  -- a
  -- b
  { modifiers = { "cmd", "ctrl" }, key = "c", action = { type = "window", command = "center" } },
  -- d
  -- e Capture Active Window (Global) @ Snapzy
  { modifiers = { "cmd", "ctrl" }, key = "f", action = { type = "window", command = "full" } },
  { modifiers = { "cmd", "ctrl" }, key = "g", action = { type = "window", command = "left" } },
  -- g
  -- h
  -- i
  -- j Capture Area (Global) @ Snapzy
  -- k
  -- l
  -- m
  { modifiers = { "cmd", "ctrl" }, key = "n", action = { type = "window", command = "top" } },
  -- o Capture Text (OCR) (Global) @ Snapzy
  { modifiers = { "cmd", "ctrl" }, key = "p", action = { type = "window", command = "previous-display" } },
  { modifiers = { "cmd", "ctrl" }, key = "r", action = { type = "window", command = "right" } },
  -- s
  { modifiers = { "cmd", "ctrl" }, key = "t", action = { type = "window", command = "bottom" } },
  -- u
  -- v Capture Fullscreen (Global) @ Snapzy
  -- w 1Password Quick Access (Global) @ 1Password
  -- x
  -- y
  -- z

  -- ==============================
  -- Cmd+Shift: 標準ホットキーと競合しがちなのであまり使わない or アプリ指定で設定
  -- ==============================

  -- a Mute (Zoom)
  { modifiers = { "cmd", "shift" }, key = "c", action = { type = "file_name_copy" } }, 
    -- Finder & Cursor only
    -- 他のアプリでの挙動：リンクコピー（Arc, Notion）
  -- g 「フォルダーへ移動」ウィンドウ (Finder)
  -- h Huddle開始・終了 (Slack), 直前に使用した文字色・背景色を適用 (Notion), ホームフォルダー (Finder)
  -- i iCloudフォルダー (Finder)
  -- j Notion AI (Global) @ Notion
  -- k Notion 検索 (Global) @ Notion
  -- l ダウンロードフォルダー (Finder), 箇条書き (Word)
  -- m インデント減らす (Word), コメント (PowerPoint, Notion)
  -- n 新規フォルダー (Finder)
  -- o 書類フォルダー (Finder)
  -- p コマンドパレット (Cursor, Warp)
  -- q
  -- r
  -- s
  -- t ぶらさげインデント解除 (Word), オートSUM (Excel)
  -- u
  -- v 書式なし貼り付け
  -- w
  -- x 打ち消し線 (Notion, Slack, Gmail, Word)
  -- y
  -- z
}
