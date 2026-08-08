#!/usr/bin/env bash
# Shared setup for nbx repl command tests — extends parent helper with commands

load "$PROJECT_ROOT/test/lib/test_helper"

# Source all command files
for _cmd_file in "$PROJECT_ROOT/lib/repl"/nbx-cmd-*; do
  [[ -f "$_cmd_file" ]] && source "$_cmd_file"
done
unset _cmd_file

# Create a test step: slot with data + history entry
# Usage: _create_test_step slot [data] [input] [filter] [type]
_create_test_step() {
  local slot="${1:-s1}" data input="${3:-f.json}" filter="${4:-.}" type="${5:-query}"
  data="${2:-"{}"}"
  echo "$data" | nbx_save_slot "$slot"
  nbx_push_history "$input" "$filter" "$slot" "$type"
}
