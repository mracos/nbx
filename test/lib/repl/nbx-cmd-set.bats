#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "nbx_cmd_set creates slot from JSON value" {
  nbx_cmd_set "threshold 30"
  assert [ -f "$NBX_DIR/slots/threshold.json" ]
  run jq '.' "$NBX_DIR/slots/threshold.json"
  assert_output "30"
  run nbx_history_depth
  assert_output "1"
}

@test "nbx_cmd_set creates slot from string value" {
  nbx_cmd_set "name hello world"
  run jq -r '.' "$NBX_DIR/slots/name.json"
  assert_output "hello world"
}

