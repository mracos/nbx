#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "nbx_cmd_rename renames slot file and history" {
  _create_test_step "old" '{"a":1}' "f.json" ".a"
  nbx_cmd_rename "old new"
  assert [ ! -f "$NBX_DIR/slots/old.json" ]
  assert [ -f "$NBX_DIR/slots/new.json" ]
  run cut -f3 "$NBX_DIR/history/1"
  assert_output "new"
}

@test "nbx_cmd_rename fails for missing slot" {
  run nbx_cmd_rename "nonexistent newname"
  assert_failure
  assert_output --partial "not found"
}

@test "nbx_cmd_rename updates slot references in history input" {
  _create_test_step "s1" '{"a":1}'
  _create_test_step "s2" '{"b":2}' "$NBX_DIR/slots/s1.json" ".b"
  nbx_cmd_rename "s1 renamed"
  run cut -f1 "$NBX_DIR/history/2"
  assert_output "$NBX_DIR/slots/renamed.json"
}
