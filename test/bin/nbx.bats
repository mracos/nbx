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

# Build an isolated PATH that mirrors the real one minus one tool, so nbx's
# `command -v` check for that tool fails regardless of where it lives (jq/fzf
# sit in /usr/bin on Linux CI but in homebrew on macOS, so dropping a single
# hard-coded dir isn't portable). `</dev/null` keeps stdin off a pipe so the
# piped-input guard doesn't fire before the dependency check.
_path_without() {
  local drop="$1" stub="$BATS_TEST_TMPDIR/stub-no-$drop" d f
  mkdir -p "$stub"
  while IFS= read -r -d: d; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      [[ -x "$f" && "${f##*/}" != "$drop" && ! -e "$stub/${f##*/}" ]] && ln -s "$f" "$stub/${f##*/}"
    done
  done <<<"$PATH:"
  printf '%s' "$stub"
}

@test "nbx requires jq" {
  PATH="$(_path_without jq)" run "$NBX_CLI" </dev/null
  assert_failure
  assert_output --partial "jq is required"
}

@test "nbx requires fzf" {
  PATH="$(_path_without fzf)" run "$NBX_CLI" </dev/null
  assert_failure
  assert_output --partial "fzf is required"
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

# --- Tabular sources (ADR 0009) ---

@test "nbx loads a CSV through mlr as a source named after the file" {
  # Stubbed: CI has no miller, and what matters is that nbx routes the file
  # through it instead of handing the CSV bytes to jq.
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/mlr" <<'STUB'
#!/usr/bin/env bash
echo '[{"name":"ana","age":31}]'
STUB
  chmod +x "$stub/mlr"
  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name,age\nana,31\n' > "$csv"

  PATH="$stub:$PATH" run bash -c "'$NBX_CLI' '$csv' </dev/null"
  assert_output --partial "users"
  assert_output --partial "mlr --icsv --ojson cat"
}

@test "nbx --help documents CSV support" {
  run "$NBX_CLI" --help
  assert_success
  assert_output --partial ".csv"
}
