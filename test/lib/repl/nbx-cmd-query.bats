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
