#!/bin/bash

set -u

status=0

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  status=1
}

require_file() {
  if [ ! -f "$1" ]; then
    fail "$2"
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "$1 is required"
    exit 1
  fi
}

search_without_tests_and_git() {
  if command -v rg >/dev/null 2>&1; then
    rg -l --no-messages --glob '!**/tests/**' --glob '!**/.git/**' "$1" "$2" "$3"
  else
    grep -R -l --exclude-dir tests --exclude-dir .git -- "$1" "$2" "$3"
  fi
}

production_lua_files() {
  if command -v rg >/dev/null 2>&1; then
    rg --files --hidden --glob '*.lua' --glob '!**/tests/**' --glob '!**/.git/**' "$repo_root"
  else
    find "$repo_root" -type f -name '*.lua' -not -path '*/tests/*' -not -path '*/.git/*'
  fi
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
dev_root=$(cd "$repo_root/../.." && pwd)
karabiner_dir="$dev_root/dotfiles/karabiner-elements"
edn_path="$karabiner_dir/goku/karabiner.edn"
json_path="$karabiner_dir/karabiner.json"
main_path="$repo_root/main.lua"

require_file "$edn_path" "karabiner.edn is missing"
require_file "$json_path" "karabiner.json is missing"
require_file "$main_path" "main.lua is missing"
require_command jq
require_command lua

if jq empty "$json_path" >/dev/null 2>&1; then
  pass "karabiner.json parses with jq"
else
  fail "karabiner.json parses with jq"
fi

if LC_ALL=C grep -Eq ':launch[[:space:]]|hammerspoon://|shell_command' "$edn_path"; then
  fail "EDN has no Karabiner app-launch intermediary"
else
  pass "EDN has no Karabiner app-launch intermediary"
fi

if LC_ALL=C grep -Eq 'hammerspoon://|launch-app|shell_command' "$json_path"; then
  fail "JSON has no Karabiner app-launch intermediary"
else
  pass "JSON has no Karabiner app-launch intermediary"
fi

if LC_ALL=C grep -Fq '[:caps_lock [:!CTOleft_shift]]' "$edn_path"; then
  pass "EDN keeps CapsLock-to-hyper modifier conversion"
else
  fail "EDN keeps CapsLock-to-hyper modifier conversion"
fi

if jq -e '
  [ .profiles[].complex_modifications.rules[].manipulators[]
    | select(.from.key_code? == "caps_lock")
  ]
  | any(.[];
      .to[0].key_code? == "left_shift"
      and ((.to[0].modifiers? // []) | sort) == ["left_command", "left_control", "left_option"]
    )
' "$json_path" >/dev/null 2>&1; then
  pass "JSON keeps CapsLock-to-hyper modifier conversion"
else
  fail "JSON keeps CapsLock-to-hyper modifier conversion"
fi

if LC_ALL=C grep -Eq 'require\("hotkeys"\)\.start\(\)|require\('\''hotkeys'\''\)\.start\(\)' "$main_path"; then
  pass "main.lua starts through hotkeys"
else
  fail "main.lua starts through hotkeys"
fi

main_require_count=$(LC_ALL=C grep -Ec '^[[:space:]]*require' "$main_path" || true)
if [ "$main_require_count" -eq 1 ]; then
  pass "main.lua has one startup require"
else
  fail "main.lua has one startup require"
fi

hotkeys_path="$repo_root/hotkeys.lua"
if [ -f "$hotkeys_path" ] && LC_ALL=C grep -Eq 'hs\.hotkey\.bind' "$hotkeys_path"; then
  pass "hotkeys.lua owns hotkey registration"
else
  fail "hotkeys.lua owns hotkey registration"
fi

bind_hits=$(mktemp "${TMPDIR:-/tmp}/launch-config-bind.XXXXXX") || exit 1
trap 'rm -f "$bind_hits"' EXIT
: >"$bind_hits"
while IFS= read -r lua_path; do
  if LC_ALL=C grep -Eq 'hs\.hotkey\.bind' "$lua_path"; then
    printf '%s\n' "$lua_path" >>"$bind_hits"
  fi
done < <(production_lua_files)
bind_file_count=$(wc -l <"$bind_hits" | tr -d ' ')
if [ "$bind_file_count" -eq 1 ] && [ "$(head -n 1 "$bind_hits")" = "$hotkeys_path" ]; then
  pass "production hs.hotkey.bind references are owned by hotkeys.lua"
else
  fail "production hs.hotkey.bind references are owned by hotkeys.lua"
  LC_ALL=C sort -u "$bind_hits" >&2
fi

for legacy in ai_command.lua app_launcher.lua utility_command.lua hud.lua; do
  if [ -e "$repo_root/$legacy" ]; then
    fail "legacy production file is absent: $legacy"
  else
    pass "legacy production file is absent: $legacy"
  fi
done

if lua "$repo_root/tests/hotkeys_test.lua"; then
  pass "central hotkey registration and delegation test"
else
  fail "central hotkey registration and delegation test"
fi

exit "$status"
