#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "nbx_cmd_hide toggles visibility" {
  _create_test_step
  run nbx_cmd_hide "1"
  assert_output --partial "hidden"
  assert nbx_is_hidden 1
  run nbx_cmd_hide "1"
  assert_output --partial "unhidden"
}

@test "nbx_cmd_hide fails for missing step" {
  run nbx_cmd_hide "99"
  assert_failure
  assert_output --partial "not found"
}

