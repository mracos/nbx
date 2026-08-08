#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "nbx_cmd_move moves step up" {
  _create_test_step "s1"
  _create_test_step "s2" '{}' "f2.json"

  run nbx_cmd_move "2 up"
  assert_success
  assert_output --partial "→"

  run cut -f3 "$NBX_DIR/history/1"
  assert_output "s2"
  run cut -f3 "$NBX_DIR/history/2"
  assert_output "s1"
}

@test "nbx_cmd_move moves step down" {
  _create_test_step "s1"
  _create_test_step "s2" '{}' "f2.json"

  run nbx_cmd_move "1 down"
  assert_success
  assert_output --partial "→"

  run cut -f3 "$NBX_DIR/history/1"
  assert_output "s2"
  run cut -f3 "$NBX_DIR/history/2"
  assert_output "s1"
}

@test "nbx_cmd_move moves step to absolute position" {
  _create_test_step "s1"
  _create_test_step "s2" '{}' "f2.json"
  _create_test_step "s3" '{}' "f3.json"

  run nbx_cmd_move "1 3"
  assert_success

  run cut -f3 "$NBX_DIR/history/3"
  assert_output "s1"
}

@test "nbx_cmd_move fails with no args" {
  run nbx_cmd_move ""
  assert_failure
  assert_output --partial "Usage"
}

@test "nbx_cmd_move fails with single arg" {
  run nbx_cmd_move "1"
  assert_failure
  assert_output --partial "Usage"
}

@test "nbx_cmd_move fails for missing step" {
  run nbx_cmd_move "99 up"
  assert_failure
  assert_output --partial "not found"
}

@test "nbx_cmd_move fails when target out of range" {
  _create_test_step

  run nbx_cmd_move "1 up"
  assert_failure
  assert_output --partial "out of range"
}

@test "nbx_cmd_move marks dirty" {
  _create_test_step "s1"
  _create_test_step "s2" '{}' "f2.json"
  NBX_DIRTY=false

  nbx_cmd_move "1 2"
  assert [ "$NBX_DIRTY" = true ]
}
