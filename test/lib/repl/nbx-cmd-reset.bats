#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "nbx_cmd_reset clears everything" {
  _create_test_step
  nbx_cmd_reset ""
  run nbx_history_depth
  assert_output "0"
  run nbx_list_slots
  assert_output ""
}

