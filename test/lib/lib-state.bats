#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# --- State ---

@test "nbx_init_state creates directories" {
  assert [ -d "$NBX_DIR/slots" ]
  assert [ -d "$NBX_DIR/history" ]
}

@test "nbx_save_slot creates named slot file" {
  echo '{"a":1}' | nbx_save_slot "test1"
  assert [ -f "$NBX_DIR/slots/test1.json" ]
  run cat "$NBX_DIR/slots/test1.json"
  assert_output '{"a":1}'
}

@test "nbx_list_slots returns saved slots" {
  echo '{}' | nbx_save_slot "foo"
  echo '[]' | nbx_save_slot "bar"
  run nbx_list_slots
  assert_output --partial "foo"
  assert_output --partial "bar"
}

@test "nbx_list_slots empty when no slots" {
  run nbx_list_slots
  assert_output ""
}

@test "nbx_slot_rows counts array length" {
  echo '[1,2,3]' | nbx_save_slot "arr"
  run nbx_slot_rows "arr"
  assert_output "3"
}

@test "nbx_slot_rows returns 1 for scalar" {
  echo '{"x":1}' | nbx_save_slot "obj"
  run nbx_slot_rows "obj"
  assert_output "1"
}

# --- History ---

@test "nbx_push_history and nbx_history_depth" {
  nbx_push_history "file1.json" ".name" "slot1"
  nbx_push_history "file2.json" ".age" "slot2"
  run nbx_history_depth
  assert_output "2"
}

@test "nbx_set_history writes entry at specific step" {
  nbx_push_history "old.json" "." "s1" "query"
  nbx_set_history 1 "new.json" ".name" "s1" "pick"

  run cut -f1 "$NBX_DIR/history/1"
  assert_output "new.json"
  run cut -f2 "$NBX_DIR/history/1"
  assert_output ".name"
  run cut -f4 "$NBX_DIR/history/1"
  assert_output "pick"
}

@test "nbx_set_history defaults type to query" {
  nbx_set_history 1 "f.json" "." "s1"
  run cut -f4 "$NBX_DIR/history/1"
  assert_output "query"
}

@test "nbx_pop_history removes last entry and its slot" {
  echo '{"x":1}' | nbx_save_slot "s1"
  echo '{"y":2}' | nbx_save_slot "s2"
  nbx_push_history "f1.json" "." "s1"
  nbx_push_history "f2.json" "." "s2"
  run nbx_pop_history
  assert_success
  run nbx_history_depth
  assert_output "1"
  assert [ ! -f "$NBX_DIR/slots/s2.json" ]
  assert [ -f "$NBX_DIR/slots/s1.json" ]
}

@test "nbx_pop_history on empty stack fails" {
  run nbx_pop_history
  assert_failure
}

@test "nbx_get_history retrieves specific step" {
  nbx_push_history "a.json" ".x" "s1" "query"
  nbx_push_history "b.json" ".y" "s2" "pipe"
  run nbx_get_history 1
  assert_output --partial "a.json"
  assert_output --partial ".x"
  assert_output --partial "query"
}

@test "nbx_get_history fails for missing step" {
  run nbx_get_history 99
  assert_failure
}

@test "nbx_reset clears slots and history" {
  echo '{}' | nbx_save_slot "x"
  nbx_push_history "f.json" "." "x"
  nbx_reset
  run nbx_list_slots
  assert_output ""
  run nbx_history_depth
  assert_output "0"
}

# --- Delete history ---

@test "nbx_delete_history removes step and renumbers" {
  echo '{"a":1}' | nbx_save_slot "s1"
  echo '{"b":2}' | nbx_save_slot "s2"
  echo '{"c":3}' | nbx_save_slot "s3"
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"

  nbx_delete_history 2

  run nbx_history_depth
  assert_output "2"

  # s2 slot removed
  assert [ ! -f "$NBX_DIR/slots/s2.json" ]
  # s1 and s3 still exist
  assert [ -f "$NBX_DIR/slots/s1.json" ]
  assert [ -f "$NBX_DIR/slots/s3.json" ]

  # Step 2 is now the old step 3
  run cut -f3 "$NBX_DIR/history/2"
  assert_output "s3"
}

# --- Move history ---

@test "nbx_move_history moves entry forward" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"

  nbx_move_history 1 3

  run cut -f3 "$NBX_DIR/history/1"
  assert_output "s2"
  run cut -f3 "$NBX_DIR/history/2"
  assert_output "s3"
  run cut -f3 "$NBX_DIR/history/3"
  assert_output "s1"
}

@test "nbx_move_history moves entry backward" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"

  nbx_move_history 3 1

  run cut -f3 "$NBX_DIR/history/1"
  assert_output "s3"
  run cut -f3 "$NBX_DIR/history/2"
  assert_output "s1"
  run cut -f3 "$NBX_DIR/history/3"
  assert_output "s2"
}

@test "nbx_move_history same position is no-op" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  run nbx_move_history 1 1
  assert_success
  run cut -f3 "$NBX_DIR/history/1"
  assert_output "s1"
}

@test "nbx_move_history out of range fails" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  run nbx_move_history 1 5
  assert_failure
  run nbx_move_history 0 1
  assert_failure
}

@test "nbx_move_history updates hidden list when moving forward" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"
  echo "1" > "$NBX_DIR/.hidden"

  nbx_move_history 1 3

  # Hidden entry moved from position 1 to position 3
  run cat "$NBX_DIR/.hidden"
  assert_output "3"
}

@test "nbx_move_history updates hidden list when moving backward" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"
  echo "3" > "$NBX_DIR/.hidden"

  nbx_move_history 3 1

  # Hidden entry moved from position 3 to position 1
  run cat "$NBX_DIR/.hidden"
  assert_output "1"
}

@test "nbx_move_history shifts other hidden entries" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"
  # Step 2 is hidden, move step 1 to 3
  echo "2" > "$NBX_DIR/.hidden"

  nbx_move_history 1 3

  # Step 2 was between from(1) and to(3), shifts down to 1
  run cat "$NBX_DIR/.hidden"
  assert_output "1"
}

# --- Stale list maintenance in delete/move ---

@test "nbx_delete_history renumbers stale entries" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"
  echo '{"a":1}' | nbx_save_slot "s1"
  echo '{"b":2}' | nbx_save_slot "s2"
  echo '{"c":3}' | nbx_save_slot "s3"
  # Steps 1 and 3 are stale
  nbx_mark_stale 1
  nbx_mark_stale 3

  nbx_delete_history 2

  # Step 1 stays at 1, old step 3 becomes 2
  run nbx_is_stale 1
  assert_success
  run nbx_is_stale 2
  assert_success
}

@test "nbx_delete_history removes deleted step from stale" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  echo '{"a":1}' | nbx_save_slot "s1"
  echo '{"b":2}' | nbx_save_slot "s2"
  nbx_mark_stale 2

  nbx_delete_history 2

  run nbx_stale_steps
  assert_output ""
}

@test "nbx_move_history updates stale list when moving forward" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"
  nbx_mark_stale 1

  nbx_move_history 1 3

  # Stale entry moved from position 1 to position 3
  run nbx_is_stale 3
  assert_success
  run nbx_is_stale 1
  assert_failure
}

@test "nbx_move_history updates stale list when moving backward" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"
  nbx_mark_stale 3

  nbx_move_history 3 1

  run nbx_is_stale 1
  assert_success
  run nbx_is_stale 3
  assert_failure
}

@test "nbx_move_history shifts other stale entries" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  nbx_push_history "f2.json" ".b" "s2" "query"
  nbx_push_history "f3.json" ".c" "s3" "query"
  # Step 2 is stale, move step 1 to 3
  nbx_mark_stale 2

  nbx_move_history 1 3

  # Step 2 was between from(1) and to(3), shifts down to 1
  run nbx_is_stale 1
  assert_success
  run nbx_is_stale 2
  assert_failure
}

@test "nbx_reset clears stale file" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  echo '{}' | nbx_save_slot "s1"
  nbx_mark_stale 1

  nbx_reset

  assert [ ! -f "$NBX_DIR/.stale" ]
}

@test "nbx_reset clears failed state" {
  nbx_push_history "f1.json" ".a" "s1" "query"
  echo '{}' | nbx_save_slot "s1"
  nbx_mark_failed 1
  nbx_save_failed_error 1 "some error"

  nbx_reset

  assert [ ! -f "$NBX_DIR/.failed" ]
  assert [ ! -d "$NBX_DIR/.failed_err" ]
}

# --- Dollar-sign slot name handling ---

@test "nbx_save_slot strips dollar prefix from name" {
  echo '42' | nbx_save_slot '$myvar'
  assert [ -f "$NBX_DIR/slots/myvar.json" ]
  assert [ ! -f "$NBX_DIR/slots/\$myvar.json" ]
}


# --- Command sources (ADR 0010) ---

@test "nbx_source_cmd_add records basename to command mapping" {
  nbx_source_cmd_add "cmd1" "gh api /user/repos"
  run cat "$NBX_DIR/.commands"
  assert_output $'cmd1\tgh api /user/repos'
}

@test "nbx_source_cmd_add dedups by label, keeping the latest command" {
  nbx_source_cmd_add "cmd1" "old command"
  nbx_source_cmd_add "cmd1" "new command"

  run nbx_source_cmd_get "cmd1"
  assert_output "new command"
  run grep -c '' "$NBX_DIR/.commands"
  assert_output "1"
}

@test "nbx_source_cmd_add flattens tabs in the command" {
  nbx_source_cmd_add "cmd1" $'a\tb'
  run nbx_source_cmd_get "cmd1"
  assert_output "a b"
}

@test "nbx_source_cmd_add flattens newlines in the command" {
  nbx_source_cmd_add "cmd1" $'a\nb'
  run nbx_source_cmd_get "cmd1"
  assert_output "a b"
}

@test "nbx_source_cmd_add preserves spaces and quotes in the command" {
  nbx_source_cmd_add "cmd1" 'jq ".foo" data.json | head'
  run nbx_source_cmd_get "cmd1"
  assert_output 'jq ".foo" data.json | head'
}

@test "nbx_source_cmd_find_label finds the label of a matching command" {
  nbx_source_cmd_add "cmd1" "gh api /user"
  nbx_source_cmd_add "cmd2" "gh api /repos"
  run nbx_source_cmd_find_label "gh api /repos"
  assert_output "cmd2"
}

@test "nbx_source_cmd_find_label empty when no command matches" {
  nbx_source_cmd_add "cmd1" "gh api /user"
  run nbx_source_cmd_find_label "gh api /other"
  assert_output ""
}

@test "nbx_source_cmd_get returns empty for a non-command source" {
  nbx_source_cmd_add "cmd1" "gh api /x"
  run nbx_source_cmd_get "users.json"
  assert_output ""
}

@test "nbx_source_cmd_get empty when no commands file" {
  run nbx_source_cmd_get "cmd1"
  assert_output ""
}

@test "nbx_is_command_source true only for recorded labels" {
  nbx_source_cmd_add "cmd1" "gh api /x"
  run nbx_is_command_source "cmd1"
  assert_success
  run nbx_is_command_source "users.json"
  assert_failure
}

@test "nbx_source_cmd_list returns all mappings" {
  nbx_source_cmd_add "cmd1" "one"
  nbx_source_cmd_add "cmd2" "two"
  run nbx_source_cmd_list
  assert_line $'cmd1\tone'
  assert_line $'cmd2\ttwo'
}
