#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "nbx_cmd_delete removes step and slot" {
  _create_test_step
  run nbx_cmd_delete "1"
  assert_success
  assert [ ! -f "$NBX_DIR/slots/s1.json" ]
  run nbx_history_depth
  assert_output "0"
}

@test "nbx_cmd_delete fails for missing step" {
  run nbx_cmd_delete "99"
  assert_failure
  assert_output --partial "not found"
}

@test "nbx_cmd_delete with no arg deletes last step" {
  _create_test_step
  run nbx_cmd_delete ""
  assert_success
  assert_output --partial "Deleted step [1]"
  run nbx_history_depth
  assert_output "0"
}

@test "nbx_cmd_delete with no arg on empty history" {
  run nbx_cmd_delete ""
  assert_success
  assert_output --partial "Nothing to delete"
}
