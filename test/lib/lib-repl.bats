#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# --- Slot name prompt ---

@test "nbx_prompt_slot_name returns default on empty input" {
  run bash -c '
    NBX_DIR=$(mktemp -d)
    mkdir -p "$NBX_DIR/history"
    source "'"$PROJECT_ROOT"'/lib/lib-state.bash"
    source "'"$PROJECT_ROOT"'/lib/lib-repl.bash"
    nbx_init_state
    nbx_prompt_slot_name <<< ""
  '
  assert_success
  assert_output --partial "s1"
}

@test "nbx_prompt_slot_name cancels on ESC" {
  run bash -c '
    NBX_DIR=$(mktemp -d)
    mkdir -p "$NBX_DIR/history"
    source "'"$PROJECT_ROOT"'/lib/lib-state.bash"
    source "'"$PROJECT_ROOT"'/lib/lib-repl.bash"
    nbx_init_state
    printf "\033" | nbx_prompt_slot_name
  '
  assert_failure
}

@test "nbx_prompt_slot_name confirms before overwriting existing slot" {
  run bash -c '
    NBX_DIR=$(mktemp -d)
    mkdir -p "$NBX_DIR/history" "$NBX_DIR/slots"
    source "'"$PROJECT_ROOT"'/lib/lib-state.bash"
    source "'"$PROJECT_ROOT"'/lib/lib-display.bash"
    source "'"$PROJECT_ROOT"'/lib/lib-repl.bash"
    nbx_init_state
    echo "existing" > "$NBX_DIR/slots/s1.json"
    printf "s1\nn\n" | nbx_prompt_slot_name
  '
  assert_failure
}

@test "nbx_prompt_slot_name allows overwrite on y" {
  run bash -c '
    NBX_DIR=$(mktemp -d)
    mkdir -p "$NBX_DIR/history" "$NBX_DIR/slots"
    source "'"$PROJECT_ROOT"'/lib/lib-state.bash"
    source "'"$PROJECT_ROOT"'/lib/lib-display.bash"
    source "'"$PROJECT_ROOT"'/lib/lib-repl.bash"
    nbx_init_state
    echo "existing" > "$NBX_DIR/slots/s1.json"
    printf "s1\ny\n" | nbx_prompt_slot_name
  '
  assert_success
  assert_output --partial "s1"
}

# --- Command resolution ---

@test "nbx_resolve_cmd matches exact command" {
  run nbx_resolve_cmd "query"
  assert_success
  assert_output "query"
}

@test "nbx_resolve_cmd matches prefix" {
  run nbx_resolve_cmd "que"
  assert_success
  assert_output "query"
}

@test "nbx_resolve_cmd fails on ambiguous prefix" {
  run nbx_resolve_cmd "s"
  assert_failure
  assert_output --partial "Ambiguous"
}

@test "nbx_resolve_cmd fails on unknown command" {
  run nbx_resolve_cmd "zzz"
  assert_failure
}

@test "nbx_resolve_cmd exact match wins over a longer prefix" {
  run nbx_resolve_cmd "ref"
  assert_success
  assert_output "ref"
}

# --- Command sources (ADR 0010) ---

@test "nbx_capture_command_sources captures stdout into a numbered source" {
  NBX_FILES=()
  nbx_capture_command_sources "echo [1,2,3]"

  assert [ -f "$NBX_DIR/sources/cmd1" ]
  run jq -c '.' "$NBX_DIR/sources/cmd1"
  assert_output "[1,2,3]"
  run nbx_source_cmd_get "cmd1"
  assert_output "echo [1,2,3]"
}

@test "nbx_capture_command_sources registers the source in NBX_FILES" {
  NBX_FILES=()
  nbx_capture_command_sources "echo [1]"
  printf '%s\n' "${NBX_FILES[@]}" > "$NBX_DIR/_files.txt"
  run grep -c 'sources/cmd1' "$NBX_DIR/_files.txt"
  assert_output "1"
}

@test "nbx_capture_command_sources numbers multiple commands" {
  NBX_FILES=()
  nbx_capture_command_sources "echo [1]" "echo [2]"
  assert [ -f "$NBX_DIR/sources/cmd1" ]
  assert [ -f "$NBX_DIR/sources/cmd2" ]
  run nbx_source_cmd_get "cmd2"
  assert_output "echo [2]"
}

@test "nbx_capture_one_command dedups an identical command to the same source" {
  NBX_FILES=()
  nbx_capture_one_command "echo [1]"
  local first="$NBX_LAST_SOURCE_LABEL"

  nbx_capture_one_command "echo [1]"
  local second="$NBX_LAST_SOURCE_LABEL"

  assert_equal "$first" "$second"           # reused, not a new label
  assert [ ! -e "$NBX_DIR/sources/cmd2" ]   # no cmd2 created
  # Registered once in NBX_FILES, not twice.
  printf '%s\n' "${NBX_FILES[@]}" > "$NBX_DIR/_files.txt"
  run grep -c 'sources/cmd1' "$NBX_DIR/_files.txt"
  assert_output "1"
}

@test "nbx_capture_one_command still numbers a different command" {
  NBX_FILES=()
  nbx_capture_one_command "echo [1]"
  nbx_capture_one_command "echo [2]"
  assert [ -e "$NBX_DIR/sources/cmd1" ]
  assert [ -e "$NBX_DIR/sources/cmd2" ]
}

@test "nbx_capture_command_sources warns and skips a command with no output" {
  NBX_FILES=()
  run nbx_capture_command_sources "true"
  assert_output --partial "produced no output"
  assert [ ! -f "$NBX_DIR/sources/cmd1" ]
}

@test "nbx_capture_command_sources wraps non-JSON output into a string array" {
  NBX_FILES=()
  run nbx_capture_command_sources $'printf "alpha\\nbeta\\n"'
  assert_output --partial "wrapped non-JSON output"

  # The captured source is now queryable JSON, not raw text.
  run jq -c '.' "$NBX_DIR/sources/cmd1"
  assert_output '["alpha","beta"]'
}

@test "nbx_wrap_if_not_json leaves valid JSON untouched" {
  mkdir -p "$NBX_DIR/sources"
  echo '[1,2,3]' > "$NBX_DIR/sources/cmd1"
  run nbx_wrap_if_not_json "$NBX_DIR/sources/cmd1" "cmd1"
  refute_output --partial "wrapped"
  run jq -c '.' "$NBX_DIR/sources/cmd1"
  assert_output '[1,2,3]'
}

@test "nbx_capture_command_sources is a no-op with no commands" {
  NBX_FILES=()
  run nbx_capture_command_sources
  assert_success
  assert [ ! -d "$NBX_DIR/sources" ]
}

@test "nbx_startup_query_target declines when stdin is not a terminal" {
  # The startup query view is fzf, which grabs /dev/tty regardless of stdin.
  # Launching it without an interactive user blocks forever, so a piped or
  # scripted run must drop straight to the REPL instead.
  NBX_FILES=("$BATS_TEST_TMPDIR/cmd1")
  : > "${NBX_FILES[0]}"

  run bash -c "source '$PROJECT_ROOT/lib/lib-repl.bash' 2>/dev/null
    nbx_history_depth() { echo 0; }
    NBX_FILES=('${NBX_FILES[0]}')
    nbx_startup_query_target" </dev/null
  assert_failure
}

# --- Tabular sources (CSV/TSV, ADR 0009) ---

@test "nbx_is_tabular_file matches csv and tsv only" {
  run nbx_is_tabular_file "users.csv"
  assert_success
  run nbx_is_tabular_file "users.TSV"
  assert_success
  run nbx_is_tabular_file "users.json"
  assert_failure
}

@test "nbx_tabular_command picks the reader from the extension" {
  run nbx_tabular_command "/tmp/users.csv"
  assert_output "mlr --icsv --ojson cat /tmp/users.csv"

  run nbx_tabular_command "/tmp/users.tsv"
  assert_output --partial "--itsv"
}

@test "nbx_capture_tabular_file loads a CSV as a JSON source named after the file" {
  _stub_mlr
  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name,age\nana,31\n' > "$csv"
  NBX_FILES=()

  nbx_capture_tabular_file "$csv"

  assert [ -f "$NBX_DIR/sources/users" ]
  run jq -c '.[0].name' "$NBX_DIR/sources/users"
  assert_output '"ana"'
  assert_equal "$NBX_LAST_SOURCE_LABEL" "users"
  assert_equal "${NBX_FILES[0]}" "$NBX_DIR/sources/users"

  run cat "$STUB_MLR_ARGV"
  assert_output --partial "--icsv --ojson cat"
}

@test "nbx_capture_tabular_file stores the mlr command so refresh can re-run it" {
  _stub_mlr
  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name,age\nana,31\n' > "$csv"
  NBX_FILES=()

  nbx_capture_tabular_file "$csv"

  run nbx_source_cmd_get users
  assert_output --partial "mlr --icsv --ojson cat"
  assert_output --partial "$csv"
}

@test "nbx_capture_tabular_file reuses the source when the same file is loaded twice" {
  _stub_mlr
  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name,age\nana,31\n' > "$csv"
  NBX_FILES=()

  nbx_capture_tabular_file "$csv"
  nbx_capture_tabular_file "$csv"

  assert_equal "$NBX_LAST_SOURCE_LABEL" "users"
  assert [ ! -e "$NBX_DIR/sources/cmd1" ]
}

@test "nbx_capture_tabular_file falls back to cmdN when the label is taken" {
  _stub_mlr
  mkdir -p "$NBX_DIR/sources"
  : > "$NBX_DIR/sources/users"
  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name,age\nana,31\n' > "$csv"
  NBX_FILES=()

  nbx_capture_tabular_file "$csv"

  assert_equal "$NBX_LAST_SOURCE_LABEL" "cmd1"
}

@test "nbx_capture_tabular_file reports the missing dependency instead of loading" {
  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name,age\nana,31\n' > "$csv"
  NBX_FILES=()

  PATH="$(_path_without_mlr)" run nbx_capture_tabular_file "$csv"

  assert_failure
  assert_output --partial "miller"
  assert [ ! -e "$NBX_DIR/sources/users" ]
}
