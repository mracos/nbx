#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "undo restores slot data after edit" {
  _create_test_step "threshold" "30" "input" "30" "input"

  # Edit step 1
  echo "42" | nbx_cmd_edit 1

  # Verify edit took effect
  run jq '.' "$NBX_DIR/slots/threshold.json"
  assert_output "42"

  # Undo
  nbx_cmd_undo 1

  # Verify original value restored
  run jq -r '.' "$NBX_DIR/slots/threshold.json"
  assert_output "30"
}

@test "undo restores history entry after edit" {
  _create_test_step "threshold" "30" "input" "30" "input"

  echo "42" | nbx_cmd_edit 1
  nbx_cmd_undo 1

  run cut -f2 "$NBX_DIR/history/1"
  assert_output "30"
}

@test "undo without arg reverts most recent edit" {
  _create_test_step "s1" '{"a":1}' "input" '{"a":1}' "input"
  _create_test_step "s2" '{"b":2}' "input" '{"b":2}' "input"

  # Edit step 2
  echo '{"b":99}' | nbx_cmd_edit 2

  # Undo without specifying step
  nbx_cmd_undo ""

  run jq -c '.' "$NBX_DIR/slots/s2.json"
  assert_output '{"b":2}'
}

@test "undo removes backup after restoring" {
  _create_test_step "threshold" "30" "input" "30" "input"

  echo "42" | nbx_cmd_edit 1
  nbx_cmd_undo 1

  run nbx_has_backup 1
  assert_failure
}

@test "undo fails when no backup exists" {
  _create_test_step "threshold" "30" "input" "30" "input"

  run nbx_cmd_undo 1
  assert_failure
  assert_output --partial "No backup"
}

@test "undo with no edits reports nothing to undo" {
  run nbx_cmd_undo ""
  assert_success
  assert_output --partial "No edits to undo"
}

@test "undo propagates staleness from restored state" {
  # Step 1: input
  _create_test_step "threshold" "30" "input" "30" "input"

  # Step 2: depends on threshold
  echo '[{"age":35}]' | nbx_save_slot "filtered"
  nbx_push_history "$NBX_DIR/slots/threshold.json" '.[] | select(.age > 30)' "filtered" "query"

  # Edit step 1 (marks step 2 stale)
  echo "40" | nbx_cmd_edit 1

  # Replay to clear staleness
  nbx_cmd_replay "--stale"

  # Undo the edit — step 2 should be stale again (value changed back)
  nbx_cmd_undo 1

  run nbx_is_stale 2
  assert_success
}

@test "undo only keeps latest backup per step" {
  _create_test_step "threshold" "30" "input" "30" "input"

  # Edit twice
  echo "42" | nbx_cmd_edit 1
  echo "99" | nbx_cmd_edit 1

  # Undo restores to the state before the second edit (42), not the original (30)
  nbx_cmd_undo 1

  run jq -r '.' "$NBX_DIR/slots/threshold.json"
  assert_output "42"
}
