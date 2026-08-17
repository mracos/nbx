#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# Helper: set up a 3-step pipeline where step 2 and 3 depend on step 1
# [1] data.json → .[] → $users
# [2] $users → .name → $names (depends on $users via input)
# [3] $users → .age → $ages (depends on $users via input)
_setup_pipeline() {
  echo '[{"name":"a","age":1},{"name":"b","age":2}]' | nbx_save_slot "users"
  echo '["a","b"]' | nbx_save_slot "names"
  echo '[1,2]' | nbx_save_slot "ages"
  nbx_push_history "data.json" ".[]" "users" "query"
  nbx_push_history "$NBX_DIR/slots/users.json" ".name" "names" "query"
  nbx_push_history "$NBX_DIR/slots/users.json" ".age" "ages" "query"
}

# --- Dependency graph ---

@test "nbx_step_deps returns slot from input field" {
  _setup_pipeline

  run nbx_step_deps 2
  assert_output "users"
}

@test "nbx_step_deps returns empty for external file input" {
  _setup_pipeline

  run nbx_step_deps 1
  assert_output ""
}

@test "nbx_step_deps detects slot reference in query" {
  echo '"marcos@test.com"' | nbx_save_slot "email"
  echo '[{"name":"a"}]' | nbx_save_slot "results"
  nbx_push_history "input" "marcos@test.com" "email" "input"
  nbx_push_history "data.json" '.[] | select(.email == $email)' "results" "query"

  run nbx_step_deps 2
  assert_line "email"
}

@test "nbx_step_deps returns both input and query deps" {
  echo '"marcos@test.com"' | nbx_save_slot "email"
  echo '[{"name":"a"}]' | nbx_save_slot "users"
  echo '[{"name":"a"}]' | nbx_save_slot "filtered"
  nbx_push_history "input" "marcos@test.com" "email" "input"
  nbx_push_history "data.json" ".[]" "users" "query"
  nbx_push_history "$NBX_DIR/slots/users.json" '.[] | select(.email == $email)' "filtered" "query"

  run nbx_step_deps 3
  assert_line "users"
  assert_line "email"
}

# --- slot_to_step ---

@test "nbx_slot_to_step finds producing step" {
  _setup_pipeline

  run nbx_slot_to_step "names"
  assert_output "2"
}

@test "nbx_slot_to_step strips dollar prefix" {
  _setup_pipeline

  run nbx_slot_to_step '$users'
  assert_output "1"
}

@test "nbx_slot_to_step fails for unknown slot" {
  _setup_pipeline

  run nbx_slot_to_step "nonexistent"
  assert_failure
}

# --- Dependents ---

@test "nbx_dependents finds direct dependents via input" {
  _setup_pipeline

  run nbx_dependents "users"
  assert_line "2"
  assert_line "3"
}

@test "nbx_dependents finds dependents via query reference" {
  echo '"marcos@test.com"' | nbx_save_slot "email"
  echo '[{"name":"a"}]' | nbx_save_slot "results"
  nbx_push_history "input" "marcos@test.com" "email" "input"
  nbx_push_history "data.json" '.[] | select(.email == $email)' "results" "query"

  run nbx_dependents "email"
  assert_output "2"
}

@test "nbx_dependents returns empty for leaf slot" {
  _setup_pipeline

  run nbx_dependents "names"
  assert_output ""
}

# --- Transitive dependents ---

@test "nbx_transitive_dependents follows chain" {
  # [1] data.json → $users
  # [2] $users → $names
  # [3] $names → $initials
  echo '[]' | nbx_save_slot "users"
  echo '[]' | nbx_save_slot "names"
  echo '[]' | nbx_save_slot "initials"
  nbx_push_history "data.json" ".[]" "users" "query"
  nbx_push_history "$NBX_DIR/slots/users.json" ".name" "names" "query"
  nbx_push_history "$NBX_DIR/slots/names.json" ".[0:1]" "initials" "query"

  run nbx_transitive_dependents "users"
  assert_line "2"
  assert_line "3"
}

@test "nbx_transitive_dependents handles fan-out" {
  _setup_pipeline

  run nbx_transitive_dependents "users"
  assert_line "2"
  assert_line "3"
}

@test "nbx_transitive_dependents returns empty for leaf" {
  _setup_pipeline

  run nbx_transitive_dependents "ages"
  assert_output ""
}

# --- Staleness ---

@test "nbx_is_stale returns false when not stale" {
  run nbx_is_stale 1
  assert_failure
}

@test "nbx_mark_stale and nbx_is_stale" {
  nbx_mark_stale 2
  run nbx_is_stale 2
  assert_success
}

@test "nbx_mark_stale is idempotent" {
  nbx_mark_stale 2
  nbx_mark_stale 2

  local count
  count=$(grep -c . "$NBX_DIR/.stale")
  [[ "$count" -eq 1 ]]
}

@test "nbx_clear_stale removes entry" {
  nbx_mark_stale 2
  nbx_mark_stale 3
  nbx_clear_stale 2

  run nbx_is_stale 2
  assert_failure
  run nbx_is_stale 3
  assert_success
}

@test "nbx_clear_stale removes file when empty" {
  nbx_mark_stale 1
  nbx_clear_stale 1
  assert [ ! -f "$NBX_DIR/.stale" ]
}

@test "nbx_stale_steps returns sorted list" {
  nbx_mark_stale 3
  nbx_mark_stale 1
  nbx_mark_stale 5

  run nbx_stale_steps
  assert_line --index 0 "1"
  assert_line --index 1 "3"
  assert_line --index 2 "5"
}

@test "nbx_stale_steps returns empty when none stale" {
  run nbx_stale_steps
  assert_output ""
}

# --- Propagation ---

@test "nbx_propagate_staleness marks direct dependents" {
  _setup_pipeline

  nbx_propagate_staleness 1

  run nbx_is_stale 2
  assert_success
  run nbx_is_stale 3
  assert_success
  # Step 1 itself should NOT be stale
  run nbx_is_stale 1
  assert_failure
}

@test "nbx_propagate_staleness follows transitive chain" {
  echo '[]' | nbx_save_slot "users"
  echo '[]' | nbx_save_slot "names"
  echo '[]' | nbx_save_slot "initials"
  nbx_push_history "data.json" ".[]" "users" "query"
  nbx_push_history "$NBX_DIR/slots/users.json" ".name" "names" "query"
  nbx_push_history "$NBX_DIR/slots/names.json" ".[0:1]" "initials" "query"

  nbx_propagate_staleness 1

  run nbx_is_stale 2
  assert_success
  run nbx_is_stale 3
  assert_success
}

@test "nbx_propagate_staleness no-op for leaf step" {
  _setup_pipeline

  nbx_propagate_staleness 3
  run nbx_stale_steps
  assert_output ""
}

# --- Failed step tracking ---

@test "nbx_is_failed returns false when not failed" {
  run nbx_is_failed 1
  assert_failure
}

@test "nbx_mark_failed and nbx_is_failed" {
  nbx_mark_failed 2
  run nbx_is_failed 2
  assert_success
}

@test "nbx_mark_failed is idempotent" {
  nbx_mark_failed 1
  nbx_mark_failed 1
  run grep -c "^1$" "$NBX_DIR/.failed"
  assert_output "1"
}

@test "nbx_clear_failed removes entry" {
  nbx_mark_failed 1
  nbx_mark_failed 2
  nbx_clear_failed 1
  run nbx_is_failed 1
  assert_failure
  run nbx_is_failed 2
  assert_success
}

@test "nbx_save_failed_error and nbx_failed_error round-trip" {
  nbx_save_failed_error 3 "Cannot index string"
  run nbx_failed_error 3
  assert_output "Cannot index string"
}

@test "nbx_clear_failed_error removes error file" {
  nbx_save_failed_error 1 "some error"
  nbx_clear_failed_error 1
  run nbx_failed_error 1
  assert_output ""
}
