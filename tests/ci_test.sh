#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

require_command lua
require_command luac

cd "$repo_root"

printf '%s\n' '== Lua syntax check =='
while IFS= read -r lua_file; do
  printf 'luac -p %s\n' "$lua_file"
  luac -p "$lua_file"
done < <(find . -type f -name '*.lua' -not -path './.git/*' | LC_ALL=C sort)

printf '%s\n' '== Lua tests =='
while IFS= read -r test_file; do
  printf 'lua %s\n' "$test_file"
  lua "$test_file"
done < <(find tests -maxdepth 1 -type f -name '*_test.lua' | LC_ALL=C sort)
