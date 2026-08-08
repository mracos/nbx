#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# --- jq_with_slots ---

@test "nbx_jq_with_slots injects existing slots as variables" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice","age":30},{"name":"bob","age":25}]' > "$src"

  echo '28' | nbx_save_slot "threshold"

  run nbx_jq_with_slots '[.[] | select(.age > $threshold)]' "$src"
  assert_success
  assert_output --partial "alice"
  refute_output --partial "bob"
}

@test "nbx_jq_with_slots works with no slots" {
  local src="$NBX_DIR/data.json"
  echo '{"x":1}' > "$src"

  run nbx_jq_with_slots '.x' "$src"
  assert_success
  assert_output "1"
}

# --- Dollar-sign jq_with_slots ---

@test "nbx_jq_with_slots strips dollar from variable names" {
  local src="$NBX_DIR/data.json"
  echo '[{"age":30},{"age":25}]' > "$src"

  # Simulate a slot file with $ in filename (legacy)
  echo '28' > "$NBX_DIR/slots/\$threshold.json"

  run nbx_jq_with_slots '[.[] | select(.age > $threshold)]' "$src"
  assert_success
  assert_output --partial "30"
  refute_output --partial "25"
}

# --- nbx_exec_jq ---

@test "nbx_exec_jq saves result and returns 0 on success" {
  local src="$NBX_DIR/data.json"
  echo '[1,2,3]' > "$src"

  run nbx_exec_jq '.[0]' "$src" "first"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/first.json"
  assert_output '1'
}

@test "nbx_exec_jq returns 1 on jq error" {
  local src="$NBX_DIR/data.json"
  echo '{"a":1}' > "$src"

  run nbx_exec_jq '.invalid[' "$src" "broken"
  assert_failure
  assert_output --partial "error"
}

@test "nbx_exec_jq saves partial result on mixed data error" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice"}, "bad_string", {"name":"bob"}]' > "$src"

  # Streaming query (no array wrap) produces partial output before error
  run nbx_exec_jq '.[] | .name' "$src" "names"
  assert_failure

  # Partial result was saved (alice emitted before the error)
  assert [ -f "$NBX_DIR/slots/names.json" ]
  run jq -r '.' "$NBX_DIR/slots/names.json"
  assert_output --partial "alice"
}

@test "nbx_exec_jq saves empty result as success" {
  local src="$NBX_DIR/data.json"
  echo '[{"age":10}]' > "$src"

  run nbx_exec_jq '[.[] | select(.age > 100)]' "$src" "filtered"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/filtered.json"
  assert_output '[]'
}
