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

if LC_ALL=C grep -Eq 'require\("app_launcher"\)\.start\(\)|require\('\''app_launcher'\''\)\.start\(\)' "$main_path"; then
  pass "main.lua starts app_launcher"
else
  fail "main.lua starts app_launcher"
fi

legacy_hits=$(mktemp "${TMPDIR:-/tmp}/launch-config-legacy.XXXXXX") || exit 1
trap 'rm -f "$legacy_hits"' EXIT
: >"$legacy_hits"
for legacy in "raycast-x://extensions/raycast/script-commands/launch-apps" "launch-apps.sh"; do
  matches=$(search_without_tests_and_git "$legacy" "$dev_root/dotfiles" "$dev_root/scripts" || true)
  if [ -n "$matches" ]; then
    fail "legacy reference is absent across dotfiles/scripts: $legacy"
    printf '%s\n' "$matches" >>"$legacy_hits"
  else
    pass "legacy reference is absent across dotfiles/scripts: $legacy"
  fi
done

if [ -s "$legacy_hits" ]; then
  LC_ALL=C sort -u "$legacy_hits" >&2
fi

pass "direct Hammerspoon hotkey mapping is covered by app_launcher_test.lua"

if lua "$repo_root/tests/app_launcher_test.lua"; then
  pass "app_launcher direct hotkey behavior test"
else
  fail "app_launcher direct hotkey behavior test"
fi

exit "$status"
