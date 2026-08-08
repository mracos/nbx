#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# --- State functions ---

@test "stash_query adds entry" {
  nbx_stash_query ".users" "120" "array"

  run nbx_stash_get 1
  assert_output ".users"
}

@test "stash_query stores rows and type" {
  nbx_stash_query ".users" "120" "array"

  run cat "$NBX_DIR/.stash"
  assert_output ".users	120	array"
}

@test "stash_query deduplicates exact matches" {
  nbx_stash_query ".users" "120" "array"
  nbx_stash_query ".users" "120" "array" || true

  run nbx_stash_count
  assert_output "1"
}

@test "stash_query allows different queries" {
  nbx_stash_query ".users" "120" "array"
  nbx_stash_query ".orders" "50" "array"

  run nbx_stash_count
  assert_output "2"
}

@test "stash_query replaces tabs with spaces" {
  nbx_stash_query ".users	| keys" "5" "array"

  run nbx_stash_get 1
  assert_output ".users | keys"
}

@test "stash_count returns 0 when empty" {
  run nbx_stash_count
  assert_output "0"
}

@test "stash_get retrieves correct entry" {
  nbx_stash_query ".users" "120" "array"
  nbx_stash_query ".orders" "50" "array"
  nbx_stash_query ".stats" "5" "object"

  run nbx_stash_get 2
  assert_output ".orders"
}

@test "stash_get fails for missing entry" {
  run nbx_stash_get 1
  assert_failure
}

@test "stash_delete removes entry" {
  nbx_stash_query ".users" "120" "array"
  nbx_stash_query ".orders" "50" "array"

  nbx_stash_delete 1

  run nbx_stash_count
  assert_output "1"
  run nbx_stash_get 1
  assert_output ".orders"
}

@test "stash_delete removes file when empty" {
  nbx_stash_query ".users" "120" "array"
  nbx_stash_delete 1

  [[ ! -f "$NBX_DIR/.stash" ]]
}

@test "stash_clear removes all files" {
  nbx_stash_query ".users" "120" "array"
  echo "1" > "$NBX_DIR/.stash_idx"

  nbx_stash_clear

  [[ ! -f "$NBX_DIR/.stash" ]]
  [[ ! -f "$NBX_DIR/.stash_idx" ]]
}

@test "stash_list outputs all entries" {
  nbx_stash_query ".users" "120" "array"
  nbx_stash_query ".orders" "50" "array"

  run nbx_stash_list
  assert_line -n 0 ".users	120	array"
  assert_line -n 1 ".orders	50	array"
}

@test "stash_list empty when no stash" {
  run nbx_stash_list
  assert_output ""
}

@test "reset clears stash" {
  nbx_stash_query ".users" "120" "array"
  nbx_reset

  run nbx_stash_count
  assert_output "0"
}
