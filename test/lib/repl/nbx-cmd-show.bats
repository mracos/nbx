#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# --- Entry resolution (nbx_cmd_show builds entries) ---
# These stub the fzf layer only — the resolution logic is real.

@test "show resolves step number to slot name" {
  _create_test_step "users" '[1]' "f.json" "." "query"
  local capture="$NBX_DIR/show-call"
  nbx_fzf_show_slot() { printf '%s\n' "$1:$2" > "$capture"; }

  run nbx_cmd_show "1"
  assert_success
  run cat "$capture"
  assert_output "1:users"
}

@test "show resolves bare slot name" {
  _create_test_step "users" '[1]' "f.json" "." "query"
  local capture="$NBX_DIR/show-call"
  nbx_fzf_show_slot() { printf '%s\n' "$1:$2" > "$capture"; }

  run nbx_cmd_show "users"
  assert_success
  run cat "$capture"
  assert_output "1:users"
}

@test "show resolves dollar-prefixed slot name" {
  _create_test_step "users" '[1]' "f.json" "." "query"
  local capture="$NBX_DIR/show-call"
  nbx_fzf_show_slot() { printf '%s\n' "$1:$2" > "$capture"; }

  run nbx_cmd_show "\$users"
  assert_success
  run cat "$capture"
  assert_output "1:users"
}

@test "show skips hidden steps when no args" {
  _create_test_step "s1" '[1]' "f.json" "." "query"
  _create_test_step "s2" '[2]' "f.json" "." "query"
  nbx_toggle_hidden 1 >/dev/null
  local capture="$NBX_DIR/show-call"
  nbx_fzf_show_slot() { printf '%s\n' "$1:$2" > "$capture"; }

  run nbx_cmd_show ""
  assert_success
  run cat "$capture"
  assert_output "2:s2"
}

@test "show warns on unknown slot" {
  run nbx_cmd_show "nonexistent"
  assert_failure
  assert_output --partial "Slot not found"
}

@test "show with no visible slots warns" {
  run nbx_cmd_show ""
  assert_failure
  assert_output --partial "No visible slots"
}

# --- Array item generation (the jq transform that feeds fzf) ---

@test "show array generates index-prefixed lines" {
  _create_test_step "items" '[{"a":1},{"a":2},{"a":3}]' "f.json" "." "query"
  local slot_file="$NBX_DIR/slots/items.json"

  run jq -r 'to_entries[] | "\(.key):\(.value | tojson)"' "$slot_file"
  assert_success
  assert_line -n 0 '0:{"a":1}'
  assert_line -n 1 '1:{"a":2}'
  assert_line -n 2 '2:{"a":3}'
}

@test "show array preview fetches item by index from source file" {
  _create_test_step "items" '[{"name":"Ana"},{"name":"Bob"}]' "f.json" "." "query"
  local slot_file="$NBX_DIR/slots/items.json"

  # Simulate what the preview command does: jq '.[ INDEX ]' on the slot file
  run jq '.[ 1 ]' "$slot_file"
  assert_success
  assert_output --partial '"name": "Bob"'
}

@test "show array handles empty array" {
  _create_test_step "empty" '[]' "f.json" "." "query"
  local slot_file="$NBX_DIR/slots/empty.json"

  run jq -r 'to_entries[] | "\(.key):\(.value | tojson)"' "$slot_file"
  assert_success
  assert_output ""
}

@test "show array handles nested objects" {
  _create_test_step "nested" '[{"a":{"b":[1,2]}}]' "f.json" "." "query"
  local slot_file="$NBX_DIR/slots/nested.json"

  run jq -r 'to_entries[] | "\(.key):\(.value | tojson)"' "$slot_file"
  assert_success
  assert_output '0:{"a":{"b":[1,2]}}'
}

# --- Multi-slot picker ---

@test "show multi builds slot labels with rows and type" {
  _create_test_step "users" '[{"a":1},{"a":2}]' "f.json" "." "query"
  _create_test_step "count" '42' "f.json" "." "query"

  # Capture what fzf receives as stdin
  local capture="$NBX_DIR/.fzf_input"
  fzf() { cat > "$capture"; return 1; }

  nbx_fzf_show_multi "1:users" "2:count" || true

  run cat "$capture"
  assert_line -n 0 --partial '$users'
  assert_line -n 0 --partial '2 array'
  assert_line -n 1 --partial '$count'
  assert_line -n 1 --partial '1 number'
}

# --- show -l (compact listing, replaces old 'slots' command) ---

@test "show -l lists all slots" {
  echo '{"a":1}' | nbx_save_slot "foo"
  echo '[1,2]' | nbx_save_slot "bar"
  run nbx_cmd_show "-l"
  assert_output --partial '$foo'
  assert_output --partial '$bar'
}

@test "show -l shows empty message" {
  run nbx_cmd_show "-l"
  assert_output --partial "No slots yet"
}
