#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "nbx_cmd_dup copies slot data" {
  _create_test_step "original" '[1,2,3]'
  nbx_cmd_dup "original copy"
  assert [ -f "$NBX_DIR/slots/copy.json" ]
  run jq -c '.' "$NBX_DIR/slots/copy.json"
  assert_output '[1,2,3]'
  run nbx_history_depth
  assert_output "2"
}

@test "nbx_cmd_dup resolves step number" {
  _create_test_step "s1" '42'
  nbx_cmd_dup "1 mycopy"
  assert [ -f "$NBX_DIR/slots/mycopy.json" ]
  run cat "$NBX_DIR/slots/mycopy.json"
  assert_output "42"
}

@test "nbx_cmd_dup fails for missing slot" {
  run nbx_cmd_dup "nonexistent copy"
  assert_failure
  assert_output --partial "not found"
}
