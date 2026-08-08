#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# --- Pin state ---

@test "nbx_pin stores slot name" {
  nbx_pin "users"
  run nbx_pinned_slot
  assert_output "users"
}

@test "nbx_pin strips dollar prefix" {
  nbx_pin "\$users"
  run nbx_pinned_slot
  assert_output "users"
}

@test "nbx_unpin clears pinned state" {
  nbx_pin "users"
  nbx_unpin
  run nbx_is_pinned
  assert_failure
}

@test "nbx_is_pinned returns false when nothing pinned" {
  run nbx_is_pinned
  assert_failure
}

@test "nbx_is_pinned returns true when pinned" {
  nbx_pin "users"
  run nbx_is_pinned
  assert_success
}

# --- Pin command ---

@test "pin with step number pins that step's slot" {
  _create_test_step "users" '[1]' "f.json" "." "query"
  nbx_cmd_pin "1"

  run nbx_pinned_slot
  assert_output "users"
}

@test "pin with slot name pins it" {
  _create_test_step "users" '[1]' "f.json" "." "query"
  nbx_cmd_pin "users"

  run nbx_pinned_slot
  assert_output "users"
}

@test "pin with dollar-prefixed slot name pins it" {
  _create_test_step "users" '[1]' "f.json" "." "query"
  nbx_cmd_pin "\$users"

  run nbx_pinned_slot
  assert_output "users"
}

@test "pin with no args pins last step" {
  _create_test_step "s1" '[1]' "f.json" "." "query"
  _create_test_step "s2" '[2]' "f.json" "." "query"
  nbx_cmd_pin ""

  run nbx_pinned_slot
  assert_output "s2"
}

@test "pin off unpins" {
  nbx_pin "users"
  nbx_cmd_pin "off"

  run nbx_is_pinned
  assert_failure
}

@test "pin unknown slot fails" {
  run nbx_cmd_pin "nonexistent"
  assert_failure
  assert_output --partial "Slot not found"
}

@test "pin with no steps fails" {
  run nbx_cmd_pin ""
  assert_failure
  assert_output --partial "No slots to pin"
}

# --- Pin cleanup ---

@test "delete clears pin if deleted slot was pinned" {
  _create_test_step "s1" '[1]' "f.json" "." "query"
  _create_test_step "s2" '[2]' "f.json" "." "query"
  nbx_pin "s1"
  nbx_delete_history 1

  run nbx_is_pinned
  assert_failure
}

@test "delete preserves pin if different slot deleted" {
  _create_test_step "s1" '[1]' "f.json" "." "query"
  _create_test_step "s2" '[2]' "f.json" "." "query"
  nbx_pin "s2"
  nbx_delete_history 1

  run nbx_is_pinned
  assert_success
  run nbx_pinned_slot
  assert_output "s2"
}

@test "reset clears pin" {
  nbx_pin "users"
  nbx_reset

  run nbx_is_pinned
  assert_failure
}

# --- Auto-replay when pinned ---

@test "prompt_replay_stale auto-replays when pinned" {
  # Step 1: source data
  echo '[{"age":25},{"age":35}]' > "$NBX_DIR/data.json"
  _create_test_step "users" '[{"age":25},{"age":35}]' "$NBX_DIR/data.json" "." "query"

  # Step 2: depends on $users via input
  echo '[{"age":35}]' | nbx_save_slot "old"
  nbx_push_history "$NBX_DIR/slots/users.json" '.[] | select(.age > 30)' "old" "query"

  # Pin step 2
  nbx_pin "old"

  # Mark step 2 stale
  nbx_mark_stale 2

  # Should auto-replay without prompting (no stdin needed)
  nbx_prompt_replay_stale

  # Step 2 should no longer be stale
  run nbx_is_stale 2
  assert_failure
}

# --- Pin display ---

@test "nbx_show_pinned renders pinned slot" {
  _create_test_step "items" '[1,2,3]' "f.json" "." "query"
  nbx_pin "items"

  run nbx_show_pinned
  assert_success
  assert_output --partial 'pin:'
  assert_output --partial '$items'
}

@test "nbx_show_pinned does nothing when nothing pinned" {
  run nbx_show_pinned
  assert_success
  assert_output ""
}

@test "nbx_show_pinned does nothing when pinned slot file missing" {
  nbx_pin "gone"
  run nbx_show_pinned
  assert_success
  assert_output ""
}
