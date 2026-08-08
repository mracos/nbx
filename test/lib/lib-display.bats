#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper

  # Source repl commands for edit
  for _cmd_file in "$PROJECT_ROOT/lib/repl"/nbx-cmd-*; do
    [[ -f "$_cmd_file" ]] && source "$_cmd_file"
  done
}

teardown() {
  rm -rf "$NBX_DIR"
}

# Strip ANSI escape sequences for assertion matching
_strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

# --- Layout: slot name first, then source ---

@test "show_notebook shows slot name before source with <- arrow" {
  echo '[1,2,3]' | nbx_save_slot "emails"
  nbx_push_history "users.json" ".[].email" "emails" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *'$emails <- users.json'* ]]
}

@test "show_notebook shows slot reference for slot-sourced steps" {
  echo '[1,2,3]' | nbx_save_slot "emails"
  nbx_push_history "users.json" ".[].email" "emails" "query"
  echo '"a@b.com"' | nbx_save_slot "first"
  nbx_push_history "$NBX_DIR/slots/emails.json" ".[0]" "first" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *'$first <- $emails'* ]]
}

@test "show_notebook shows query after pipe separator" {
  echo '[1]' | nbx_save_slot "ids"
  nbx_push_history "data.json" ".[] | .id" "ids" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  # │ is the box-drawing separator between source and query
  [[ "$stripped" == *'.[] | .id'* ]]
}

@test "show_notebook numbers steps sequentially" {
  echo '1' | nbx_save_slot "a"
  nbx_push_history "f.json" ".a" "a" "query"
  echo '2' | nbx_save_slot "b"
  nbx_push_history "f.json" ".b" "b" "query"
  echo '3' | nbx_save_slot "c"
  nbx_push_history "f.json" ".c" "c" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *'[1] $a'* ]]
  [[ "$stripped" == *'[2] $b'* ]]
  [[ "$stripped" == *'[3] $c'* ]]
}

@test "show_notebook empty when no history" {
  run nbx_show_notebook
  assert_output ""
}

# --- Scalar value preview ---

@test "show_notebook shows inline value for string slot" {
  echo '"user@example.com"' | nbx_save_slot "email"
  nbx_push_history "users.json" ".[0].email" "email" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *'= user@example.com'* ]]
}

@test "show_notebook shows inline value for number slot" {
  echo '42' | nbx_save_slot "count"
  nbx_push_history "data.json" ".total" "count" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *'= 42'* ]]
}

@test "show_notebook shows inline value for boolean slot" {
  echo 'true' | nbx_save_slot "active"
  nbx_push_history "data.json" ".active" "active" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *'= true'* ]]
}

@test "show_notebook shows rows and type for arrays" {
  echo '[1,2,3,4,5]' | nbx_save_slot "items"
  nbx_push_history "data.json" ".items" "items" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *'5 array'* ]]
  [[ "$stripped" != *'= '* ]]
}

@test "show_notebook shows rows and type for objects" {
  echo '{"a":1}' | nbx_save_slot "obj"
  nbx_push_history "data.json" ".config" "obj" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *'1 object'* ]]
  [[ "$stripped" != *'= '* ]]
}

# --- Tag display ---

@test "show_notebook displays (hidden) tag" {
  echo '{}' | nbx_save_slot "s1"
  nbx_push_history "f.json" "." "s1" "query"
  nbx_toggle_hidden 1

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *"(hidden)"* ]]
}

@test "show_notebook displays (stale) tag" {
  echo '{}' | nbx_save_slot "s1"
  nbx_push_history "f.json" "." "s1" "query"
  nbx_mark_stale 1

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *"(stale)"* ]]
}

@test "show_notebook displays (edited) tag when backup exists" {
  echo '"30"' | nbx_save_slot "threshold"
  nbx_push_history "input" "30" "threshold" "input"

  echo "42" | nbx_cmd_edit 1

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *"(edited)"* ]]
}

@test "show_notebook does not display (edited) after undo" {
  echo '"30"' | nbx_save_slot "threshold"
  nbx_push_history "input" "30" "threshold" "input"

  echo "42" | nbx_cmd_edit 1
  nbx_cmd_undo 1

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" != *"(edited)"* ]]
}

@test "show_notebook shows no tags on clean step" {
  echo '{}' | nbx_save_slot "s1"
  nbx_push_history "f.json" "." "s1" "query"

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" != *"(hidden)"* ]]
  [[ "$stripped" != *"(stale)"* ]]
  [[ "$stripped" != *"(edited)"* ]]
}

@test "show_notebook displays (failed) tag" {
  echo '{}' | nbx_save_slot "s1"
  nbx_push_history "f.json" "." "s1" "query"
  nbx_mark_failed 1

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *"(failed)"* ]]
}

@test "show_notebook can show multiple tags" {
  echo '{}' | nbx_save_slot "threshold"
  nbx_push_history "input" "30" "threshold" "input"

  echo "42" | nbx_cmd_edit 1
  nbx_mark_stale 1

  run nbx_show_notebook
  local stripped
  stripped=$(printf '%s' "$output" | _strip_ansi)
  [[ "$stripped" == *"(stale)"* ]]
  [[ "$stripped" == *"(edited)"* ]]
}
