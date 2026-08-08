#!/usr/bin/env bats
# bats file_tags=integration

bats_require_minimum_version 1.5.0

load "$PROJECT_ROOT/test/test_helper.bash"

NBX_CLI="$PROJECT_ROOT/bin/nbx"
NBX_LIB="$PROJECT_ROOT/lib"

# Helper: set up a sourced nbx environment (state + display + jq + bulk)
# Sets NBX_DIR to a temp dir with slots/history initialized
_nbx_env() {
  export NBX_DIR
  NBX_DIR="$(mktemp -d)"
  export LIB_DIR="$NBX_LIB"
  source "$NBX_LIB/lib-state.bash"
  source "$NBX_LIB/lib-display.bash"
  source "$NBX_LIB/lib-jq.bash"
  source "$NBX_LIB/lib-bulk.bash"
  source "$NBX_LIB/lib-repl.bash"
  nbx_init_state
}

@test "nbx --help prints usage" {
  run "$NBX_CLI" --help
  assert_success
  assert_output --partial "nbx"
  assert_output --partial "USAGE"
}

@test "nbx requires jq" {
  PATH="/usr/bin" run -127 "$NBX_CLI"
  assert_failure
}

@test "nbx requires fzf" {
  # Remove fzf from PATH but keep jq
  PATH="$(dirname "$(command -v jq)")" run -127 "$NBX_CLI"
  assert_failure
}

@test "nbx cheatsheet file exists and has content" {
  local cheatsheet="$NBX_LIB/cheatsheet.txt"
  assert [ -f "$cheatsheet" ]
  run grep -c "." "$cheatsheet"
  assert_success
  run grep "Identity" "$cheatsheet"
  assert_success
}

# --- REPO_ROOT ---

@test "nbx finds REPO_ROOT via dirname chain, not CLAUDE.md walk" {
  run grep -c "CLAUDE.md" "$NBX_CLI"
  assert_output "0"
}


# --- Command sources (ADR 0010) ---

@test "nbx --help documents command args" {
  run "$NBX_CLI" --help
  assert_success
  assert_output --partial "run as a command"
}

@test "nbx rejects piped input with a hint" {
  run bash -c "echo '[1,2,3]' | '$NBX_CLI'"
  assert_failure
  assert_output --partial "doesn't read piped input"
  assert_output --partial "nbx 'your command'"
}

@test "nbx runs a non-file positional arg as a command source" {
  run bash -c "'$NBX_CLI' 'echo [1,2,3]' </dev/null"
  assert_output --partial "cmd1"
}

@test "nbx warns when a command arg produces no output" {
  run bash -c "'$NBX_CLI' 'true' </dev/null"
  assert_output --partial "produced no output"
}

@test "nbx reads an existing file as a data source, not a command" {
  local f="$BATS_TEST_TMPDIR/data.json"
  echo '[1,2,3]' > "$f"
  run bash -c "'$NBX_CLI' '$f' </dev/null"
  assert_output --partial "$(basename "$f")"
}
