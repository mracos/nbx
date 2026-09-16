#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper

  # Mock interactive functions
  nbx_fzf_query() { echo "$MOCK_QUERY"; }
  nbx_prompt_slot_name() { echo "$MOCK_SLOT"; }
  nbx_pick_input() { echo "$MOCK_INPUT"; }
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "query saves result and creates history on success" {
  local data_file="$NBX_DIR/data.json"
  echo '[{"name":"alice"},{"name":"bob"}]' > "$data_file"

  MOCK_QUERY='[.[].name]'
  MOCK_SLOT='names'

  run nbx_cmd_query "$data_file"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/names.json"
  assert_output '["alice","bob"]'

  run nbx_history_depth
  assert_output "1"
}

@test "query rejects jq errors and creates no history" {
  local data_file="$NBX_DIR/data.json"
  echo '{"name":"alice"}' > "$data_file"

  MOCK_QUERY='.invalid_syntax['
  MOCK_SLOT='broken'

  run nbx_cmd_query "$data_file"
  assert_failure

  run nbx_history_depth
  assert_output "0"
}

@test "query accepts empty results" {
  local data_file="$NBX_DIR/data.json"
  echo '[{"name":"alice"}]' > "$data_file"

  MOCK_QUERY='[.[] | select(.age > 100)]'
  MOCK_SLOT='filtered'

  run nbx_cmd_query "$data_file"
  assert_success

  run nbx_history_depth
  assert_output "1"
}

@test "query with HIDE prefix toggles hidden" {
  local data_file="$NBX_DIR/data.json"
  echo '["a","b"]' > "$data_file"

  nbx_fzf_query() { echo "HIDE:.[0]"; }
  MOCK_SLOT='first'

  nbx_cmd_query "$data_file"

  run nbx_is_hidden 1
  assert_success
}

# --- Command sugar: query <command> = source + query (ADR 0010) ---

@test "query with a command creates a source and queries it" {
  MOCK_QUERY='.[0]'
  MOCK_SLOT='first'

  run nbx_cmd_query 'echo [1,2,3]'
  assert_success

  # Source captured and recorded for refresh...
  assert [ -f "$NBX_DIR/sources/cmd1" ]
  run nbx_source_cmd_get "cmd1"
  assert_output "echo [1,2,3]"
  # ...and the jq step ran against it.
  run jq -c '.' "$NBX_DIR/slots/first.json"
  assert_output "1"
}

@test "query with an existing source label uses its snapshot, not a re-run" {
  mkdir -p "$NBX_DIR/sources"
  echo '[7,8]' > "$NBX_DIR/sources/cmd1"
  NBX_FILES=("$NBX_DIR/sources/cmd1")
  nbx_source_cmd_add "cmd1" "echo SHOULD_NOT_RUN"

  MOCK_QUERY='.'
  MOCK_SLOT='out'
  run nbx_cmd_query "cmd1"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/out.json"
  assert_output "[7,8]"
}

@test "query with an unresolved \$slot is still 'not found', not a command" {
  run nbx_cmd_query '$nope'
  assert_failure
  assert_output --partial "Not found"
  assert [ ! -f "$NBX_DIR/sources/cmd1" ]
}

@test "query with a command that yields nothing fails without a step" {
  run nbx_cmd_query "true"
  assert_failure
  run nbx_history_depth
  assert_output "0"
}

# --- Slot name sanitizing (nbx_sanitize_slot_name) ---

@test "slot name with spaces folds to underscores" {
  run nbx_sanitize_slot_name "bigger name payees"
  assert_output "bigger_name_payees"
}

@test "slot name strips punctuation and collapses/trims separators" {
  run nbx_sanitize_slot_name "  a/b--c!!  "
  assert_output "a_b_c"
}

@test "slot name starting with a digit gets an underscore prefix" {
  run nbx_sanitize_slot_name "3rd try"
  assert_output "_3rd_try"
}

@test "already-valid slot name is unchanged" {
  run nbx_sanitize_slot_name "s1"
  assert_output "s1"
}

@test "slot name with no usable characters sanitizes to empty" {
  run nbx_sanitize_slot_name "!!!"
  assert_output ""
}

@test "a space-named slot stays usable as a jq variable" {
  local data_file="$NBX_DIR/data.json"
  echo '[10,20,30]' > "$data_file"

  nbx_fzf_query() { echo "."; }
  nbx_prompt_slot_name() { echo "$(nbx_sanitize_slot_name "bigger name payees")"; }
  nbx_cmd_query "$data_file"

  # The slot file uses the safe name...
  assert [ -f "$NBX_DIR/slots/bigger_name_payees.json" ]
  # ...and it resolves as a jq variable in a later query (spaces would make jq
  # reject the --slurpfile identifier).
  nbx_build_slot_args
  run jq "${NBX_JQ_ARGS[@]}" -n "${NBX_JQ_UNWRAP}"'$bigger_name_payees | add'
  assert_output "60"
}

# --- Input display hint (nbx_input_label) ---

@test "input label is the basename for a file source" {
  run nbx_input_label "$NBX_DIR/sources/cmd1"
  assert_output "cmd1"

  run nbx_input_label "/some/dir/2025-03-07-personal.json"
  assert_output "2025-03-07-personal.json"
}

@test "input label reads a slot as \$name" {
  run nbx_input_label "$NBX_DIR/slots/threshold.json"
  assert_output '$threshold'
}

@test "query passes the input label to the fzf hint" {
  local data_file="$NBX_DIR/2025-03-07-personal.json"
  echo '[1,2,3]' > "$data_file"

  # Capture the 3rd arg (context_label) fzf is called with, still return a query.
  nbx_fzf_query() { printf '%s' "$3" > "$NBX_DIR/.seen_label"; echo "."; }
  nbx_prompt_slot_name() { echo "s1"; }

  nbx_cmd_query "$data_file"

  run cat "$NBX_DIR/.seen_label"
  assert_output "2025-03-07-personal.json"
}

# --- Startup auto-query (nbx_startup_query_target) ---
#
# These cover the decision, not the terminal check in front of it: `run`
# inherits bats' stdin, so the real check answers yes on a developer's terminal
# and no in CI. Stub it and the tests mean the same thing in both places; the
# check itself is covered in lib-repl.bats against a real piped stdin.

@test "startup auto-opens query on a single source, passing its basename" {
  nbx_interactive() { return 0; }
  NBX_FILES=("$NBX_DIR/2025-03-07-personal.json")

  run nbx_startup_query_target
  assert_success
  assert_output "2025-03-07-personal.json"
}

@test "startup auto-opens with the picker (empty arg) for multiple sources" {
  nbx_interactive() { return 0; }
  NBX_FILES=("$NBX_DIR/a.json" "$NBX_DIR/b.json")

  run nbx_startup_query_target
  assert_success
  assert_output ""
}

@test "startup stays at the REPL when there are no sources" {
  NBX_FILES=()

  run nbx_startup_query_target
  assert_failure
}

@test "startup stays at the REPL when resuming a notebook with steps" {
  local data_file="$NBX_DIR/data.json"
  echo '[1,2,3]' > "$data_file"
  MOCK_QUERY='.'
  MOCK_SLOT='s1'
  nbx_cmd_query "$data_file"
  NBX_FILES=("$data_file")

  run nbx_history_depth
  assert_output "1"

  run nbx_startup_query_target
  assert_failure
}

# --- Tabular sources (ADR 0009) ---

@test "query on a CSV path converts it before jq sees it" {
  _stub_mlr '[{"name":"ana","age":31},{"name":"bruno","age":25}]'

  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name,age\nana,31\nbruno,25\n' > "$csv"
  MOCK_QUERY='[.[] | select(.age > 30) | .name]'
  MOCK_SLOT='grown'
  NBX_FILES=()

  run nbx_cmd_query "$csv"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/grown.json"
  assert_output '["ana"]'
}

@test "query records the converted source, not the CSV path, in history" {
  _stub_mlr

  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name\nana\n' > "$csv"
  MOCK_QUERY='.'
  MOCK_SLOT='rows'
  NBX_FILES=()

  nbx_cmd_query "$csv"

  run nbx_history_field 1 input
  assert_output "$NBX_DIR/sources/users"
}

@test "query on a CSV fails cleanly without miller" {
  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name\nana\n' > "$csv"
  MOCK_QUERY='.'
  MOCK_SLOT='rows'
  NBX_FILES=()

  PATH="$(_path_without_mlr)" run nbx_cmd_query "$csv"
  assert_failure
  assert_output --partial "miller"

  run nbx_history_depth
  assert_output "0"
}
