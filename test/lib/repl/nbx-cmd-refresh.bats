#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# Register a -c source with an initial snapshot and command.
_seed_command_source() {
  local label="$1" cmd="$2" initial="${3:-[1]}"
  mkdir -p "$NBX_DIR/sources"
  echo "$initial" > "$NBX_DIR/sources/$label"
  NBX_FILES=("$NBX_DIR/sources/$label")
  nbx_source_cmd_add "$label" "$cmd"
}

@test "refresh re-runs the command and overwrites the snapshot" {
  _seed_command_source "cmd1" "echo [1,2,3]" "[1]"

  nbx_cmd_refresh "cmd1" <<< "n"

  run jq -c '.' "$NBX_DIR/sources/cmd1"
  assert_output "[1,2,3]"
}

@test "refresh accepts the \$-prefixed label form" {
  _seed_command_source "cmd1" "echo [5]" "[1]"

  nbx_cmd_refresh '$cmd1' <<< "n"

  run jq -c '.' "$NBX_DIR/sources/cmd1"
  assert_output "[5]"
}

@test "refresh marks steps reading the source as stale" {
  _seed_command_source "cmd1" "echo [1,2]" "[1]"
  jq '.' "$NBX_DIR/sources/cmd1" | nbx_save_slot "s1"
  nbx_push_history "$NBX_DIR/sources/cmd1" "." "s1" "query"

  nbx_cmd_refresh "cmd1" <<< "n"

  run nbx_is_stale 1
  assert_success
}

@test "refresh echoes the command it runs" {
  _seed_command_source "cmd1" "echo [1]" "[0]"

  run nbx_cmd_refresh "cmd1" <<< "n"
  assert_output --partial "Running: echo [1]"
}

@test "refresh warns on a non-command source" {
  mkdir -p "$NBX_DIR/sources"
  echo '[1]' > "$NBX_DIR/sources/users.json"
  NBX_FILES=("$NBX_DIR/sources/users.json")

  run nbx_cmd_refresh "users"
  assert_failure
  assert_output --partial "not a command source"
}

@test "refresh with no command sources warns" {
  run nbx_cmd_refresh
  assert_failure
  assert_output --partial "No command sources"
}

@test "refresh with no arg re-runs every command source" {
  _seed_command_source "cmd1" "echo [1,1]" "[0]"
  nbx_source_cmd_add "cmd2" "echo [2,2]"
  echo '[0]' > "$NBX_DIR/sources/cmd2"
  NBX_FILES+=("$NBX_DIR/sources/cmd2")

  nbx_cmd_refresh <<< "n"

  run jq -c '.' "$NBX_DIR/sources/cmd1"
  assert_output "[1,1]"
  run jq -c '.' "$NBX_DIR/sources/cmd2"
  assert_output "[2,2]"
}

@test "refresh keeps the previous snapshot when the command yields nothing" {
  _seed_command_source "cmd1" "true" "[42]"

  run nbx_cmd_refresh "cmd1"
  assert_output --partial "no output"

  run jq -c '.' "$NBX_DIR/sources/cmd1"
  assert_output "[42]"
}
