#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# --- ipynb persistence ---

@test "nbx_ipynb_new creates valid notebook" {
  local nb="$NBX_DIR/test.ipynb"
  NBX_FILES=("/tmp/a.json" "/tmp/b.json")
  nbx_ipynb_new "$nb" "${NBX_FILES[@]}"

  assert [ -f "$nb" ]
  run jq '.nbformat' "$nb"
  assert_output "4"
  run jq '.metadata.nbx.version' "$nb"
  assert_output '"0.1"'
  run jq '.metadata.nbx.sources | length' "$nb"
  assert_output "2"
  run jq '.cells | length' "$nb"
  assert_output "0"
}

@test "nbx_ipynb_save persists cells from history" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/input.json"
  echo '[{"name":"alice"},{"name":"bob"}]' > "$src"
  NBX_FILES=("$src")

  jq '.[0]' "$src" | nbx_save_slot "s1"
  nbx_push_history "$src" ".[0]" "s1" "query"

  jq 'map(.name)' "$src" | nbx_save_slot "s2"
  nbx_push_history "$src" "map(.name)" "s2" "pipe"

  nbx_ipynb_save "$nb"

  assert [ -f "$nb" ]
  run jq '.cells | length' "$nb"
  assert_output "2"
  run jq -r '.cells[0].metadata.nbx.filter' "$nb"
  assert_output ".[0]"
  run jq -r '.cells[1].metadata.nbx.type' "$nb"
  assert_output "pipe"
}

# --- ipynb load ---

@test "nbx_ipynb_load restores state from cached outputs" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/input.json"
  echo '[{"name":"alice"},{"name":"bob"}]' > "$src"
  NBX_FILES=("$src")

  # Build a notebook with 2 cells
  jq '.[0]' "$src" | nbx_save_slot "s1"
  nbx_push_history "$src" ".[0]" "s1" "query"
  jq 'map(.name)' "$src" | nbx_save_slot "s2"
  nbx_push_history "$src" "map(.name)" "s2" "pipe"
  nbx_ipynb_save "$nb"

  # Reset and reload — remove source file to prove we use cache, not re-execution
  nbx_reset
  rm "$src"
  run nbx_history_depth
  assert_output "0"

  nbx_ipynb_load "$nb" >/dev/null 2>&1
  run nbx_history_depth
  assert_output "2"

  # Check slot s1 was restored from cache
  assert [ -f "$NBX_DIR/slots/s1.json" ]
  run jq -c '.' "$NBX_DIR/slots/s1.json"
  assert_output '{"name":"alice"}'

  # Check slot s2 was restored from cache
  run jq -c '.' "$NBX_DIR/slots/s2.json"
  assert_output '["alice","bob"]'
}

@test "nbx_ipynb_load handles text as string (not array)" {
  local nb="$NBX_DIR/test.ipynb"

  # Notebook with text stored as a plain string instead of an array
  _create_test_notebook "$nb" '[{
    "cell_type": "code", "id": "cell-1",
    "source": ["jq . data.json"],
    "metadata": {"nbx": {"slot": "s1", "type": "query", "input": "/gone/file.json", "filter": "."}},
    "outputs": [{"output_type": "stream", "name": "stdout", "text": "{\"stringy\":true}"}],
    "execution_count": 1
  }]'

  NBX_FILES=()
  nbx_ipynb_load "$nb"

  run nbx_history_depth
  assert_output "1"
  run jq -c '.' "$NBX_DIR/slots/s1.json"
  assert_output '{"stringy":true}'
}

@test "nbx_ipynb_load re-executes pick from jq filter when cache invalid" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/input.json"
  echo '[{"name":"alice"},{"name":"bob"},{"name":"charlie"}]' > "$src"
  NBX_FILES=("$src")

  # Notebook with pick cell that has a jq filter and INVALID cached output
  _create_test_notebook "$nb" "$(jq -n --arg src "$src" '[{
    "cell_type": "code", "id": "cell-1",
    "source": ["jq \u0027[.[0], .[2]]\u0027 input.json"],
    "metadata": {"nbx": {"slot": "s1", "type": "pick", "input": $src, "filter": "[.[0], .[2]]"}},
    "outputs": [{"output_type": "stream", "name": "stdout", "text": ["not valid json"]}],
    "execution_count": 1
  }]')"

  nbx_ipynb_load "$nb" >/dev/null 2>&1

  run nbx_history_depth
  assert_output "1"
  run jq -c '.' "$NBX_DIR/slots/s1.json"
  assert_output '[{"name":"alice"},{"name":"charlie"}]'
}

@test "nbx_ipynb_load uses cached output when source missing" {
  local nb="$NBX_DIR/test.ipynb"

  # Create notebook referencing a file that won't exist on load
  _create_test_notebook "$nb" '[{
    "cell_type": "code", "id": "cell-1",
    "source": ["jq . /gone/file.json"],
    "metadata": {"nbx": {"slot": "s1", "type": "query", "input": "/gone/file.json", "filter": "."}},
    "outputs": [{"output_type": "stream", "name": "stdout", "text": ["{\"cached\":true}"]}],
    "execution_count": 1
  }]'

  NBX_FILES=()
  nbx_ipynb_load "$nb"

  run nbx_history_depth
  assert_output "1"
  run cat "$NBX_DIR/slots/s1.json"
  assert_output '{"cached":true}'
}

@test "nbx_ipynb_load restores input type slots" {
  local nb="$NBX_DIR/test.ipynb"

  _create_test_notebook "$nb" '[{
    "cell_type": "code", "id": "cell-1",
    "source": ["set threshold 30"],
    "metadata": {"nbx": {"slot": "threshold", "type": "input", "input": "input", "filter": "30"}},
    "outputs": [{"output_type": "stream", "name": "stdout", "text": ["30"]}],
    "execution_count": 1
  }]'

  NBX_FILES=()
  nbx_ipynb_load "$nb" >/dev/null 2>&1
  run nbx_history_depth
  assert_output "1"
  run jq '.' "$NBX_DIR/slots/threshold.json"
  assert_output "30"
}

# --- Atomic save (never nuke notebook) ---

@test "nbx_ipynb_save writes to temp then moves atomically" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/input.json"
  echo '[{"name":"alice"}]' > "$src"
  NBX_FILES=("$src")

  # Save a valid notebook
  jq '.[0]' "$src" | nbx_save_slot "s1"
  nbx_push_history "$src" ".[0]" "s1" "query"
  nbx_ipynb_save "$nb"
  assert [ -f "$nb" ]

  # Temp file should not remain after successful save
  assert [ ! -f "$NBX_DIR/.save_tmp.ipynb" ]
  # Cells dir should be cleaned up
  assert [ ! -d "$NBX_DIR/.save_cells" ]

  # Saved notebook must be valid JSON with correct structure
  run jq '.cells | length' "$nb"
  assert_output "1"
  run jq '.nbformat' "$nb"
  assert_output "4"
}

@test "nbx_ipynb_save handles large outputs without argv overflow" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/input.json"

  # Generate a large JSON array (~500KB)
  jq -n '[range(10000) | {id: ., name: "user-\(.)"}]' > "$src"
  NBX_FILES=("$src")

  jq '.' "$src" | nbx_save_slot "big"
  nbx_push_history "$src" "." "big" "query"
  nbx_ipynb_save "$nb"

  assert [ -f "$nb" ]
  run jq '.cells | length' "$nb"
  assert_output "1"
  run jq '.cells[0].metadata.nbx.slot' "$nb"
  assert_output '"big"'
}

# --- Dollar-sign load ---

@test "nbx_ipynb_load strips dollar from slot names" {
  local nb="$NBX_DIR/test.ipynb"

  _create_test_notebook "$nb" '[{
    "cell_type": "code", "id": "cell-1",
    "source": ["set email test@test.com"],
    "metadata": {"nbx": {"slot": "$email", "type": "input", "input": "input", "filter": "\"test@test.com\""}},
    "outputs": [{"output_type": "stream", "name": "stdout", "text": ["\"test@test.com\""]}],
    "execution_count": 1
  }]'

  NBX_FILES=()
  nbx_ipynb_load "$nb" >/dev/null 2>&1

  # Slot file should be without $
  assert [ -f "$NBX_DIR/slots/email.json" ]
  run jq -r '.' "$NBX_DIR/slots/email.json"
  assert_output "test@test.com"
}

# --- Load uses cache, not re-execution ---

@test "nbx_ipynb_load is fast (uses cache, not re-execution)" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/input.json"
  echo '[{"name":"alice"}]' > "$src"
  NBX_FILES=("$src")

  jq '.[0]' "$src" | nbx_save_slot "s1"
  nbx_push_history "$src" ".[0]" "s1" "query"
  nbx_ipynb_save "$nb"

  # Change source file — if load re-executes, result would differ
  echo '[{"name":"CHANGED"}]' > "$src"

  nbx_reset
  nbx_ipynb_load "$nb" >/dev/null 2>&1

  # Should have the original cached value, not the changed file
  run jq -r '.name' "$NBX_DIR/slots/s1.json"
  assert_output "alice"
}

# --- Staleness persistence via execution_count ---

@test "nbx_ipynb_save writes execution_count null for stale steps" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/input.json"
  echo '[{"name":"alice"}]' > "$src"
  NBX_FILES=("$src")

  jq '.[0]' "$src" | nbx_save_slot "s1"
  nbx_push_history "$src" ".[0]" "s1" "query"
  jq 'map(.name)' "$src" | nbx_save_slot "s2"
  nbx_push_history "$src" "map(.name)" "s2" "pipe"

  # Mark step 2 as stale
  nbx_mark_stale 2

  nbx_ipynb_save "$nb"

  # Step 1: normal execution_count
  run jq '.cells[0].execution_count' "$nb"
  assert_output "1"

  # Step 2: null execution_count (stale)
  run jq '.cells[1].execution_count' "$nb"
  assert_output "null"
}

@test "nbx_ipynb_load restores stale from execution_count null" {
  local nb="$NBX_DIR/test.ipynb"

  _create_test_notebook "$nb" '[
    {
      "cell_type": "code", "id": "cell-1",
      "source": ["jq .[0] input.json"],
      "metadata": {"nbx": {"slot": "s1", "type": "query", "input": "input.json", "filter": ".[0]"}, "jupyter": {"source_hidden": false, "outputs_hidden": false}},
      "outputs": [{"output_type": "stream", "name": "stdout", "text": ["{\"name\":\"alice\"}"]}],
      "execution_count": 1
    },
    {
      "cell_type": "code", "id": "cell-2",
      "source": ["jq map(.name) input.json"],
      "metadata": {"nbx": {"slot": "s2", "type": "pipe", "input": "input.json", "filter": "map(.name)"}, "jupyter": {"source_hidden": false, "outputs_hidden": false}},
      "outputs": [{"output_type": "stream", "name": "stdout", "text": ["[\"alice\"]"]}],
      "execution_count": null
    }
  ]'

  NBX_FILES=()
  nbx_ipynb_load "$nb" >/dev/null 2>&1

  # Step 1 should NOT be stale
  run nbx_is_stale 1
  assert_failure

  # Step 2 should be stale (execution_count was null)
  run nbx_is_stale 2
  assert_success
}

@test "nbx_ipynb_save and load round-trip preserves staleness" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/input.json"
  echo '[{"name":"alice"}]' > "$src"
  NBX_FILES=("$src")

  jq '.[0]' "$src" | nbx_save_slot "s1"
  nbx_push_history "$src" ".[0]" "s1" "query"
  jq 'map(.name)' "$src" | nbx_save_slot "s2"
  nbx_push_history "$src" "map(.name)" "s2" "pipe"

  nbx_mark_stale 2
  nbx_ipynb_save "$nb"

  # Reset and reload
  nbx_reset
  nbx_ipynb_load "$nb" >/dev/null 2>&1

  run nbx_is_stale 1
  assert_failure
  run nbx_is_stale 2
  assert_success
}

# --- Backslash preservation (save/load round-trip) ---

@test "nbx_ipynb_save and load preserve backslashes across multiple cycles" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/input.json"
  echo '["a\nb", "c"]' > "$src"
  NBX_FILES=("$src")

  local filter='split("\n") | map(select(length > 0))'
  echo '["a","b","c"]' | nbx_save_slot "s1"
  nbx_push_history "$src" "$filter" "s1" "query"

  # Three save/load cycles — filter must not change
  local cycle
  for cycle in 1 2 3; do
    nbx_ipynb_save "$nb"
    nbx_reset
    nbx_ipynb_load "$nb" >/dev/null 2>&1
  done

  local final_filter
  final_filter=$(cut -f2 "$NBX_DIR/history/1")
  assert_equal "$filter" "$final_filter"
}

# --- Preview backslash handling ---

@test "printf %s in fzf change binding preserves backslashes" {
  # Regression: echo {q} ate backslashes, printf '%s' {q} preserves them
  local query_file="$NBX_DIR/.query"
  # Simulate what the fzf bind does: printf '%s' <query> > file
  printf '%s' 'test("\\w+")' > "$query_file"
  run cat "$query_file"
  assert_output 'test("\\w+")'
}

# --- Command sources (ADR 0010) ---

@test "nbx_ipynb_save snapshots command sources and excludes their temppaths" {
  local nb="$NBX_DIR/test.ipynb"
  mkdir -p "$NBX_DIR/sources"
  local cmdsrc="$NBX_DIR/sources/cmd1"
  local filesrc="$NBX_DIR/real.json"
  echo '[1,2,3]' > "$cmdsrc"
  echo '[4,5,6]' > "$filesrc"
  NBX_FILES=("$filesrc" "$cmdsrc")
  nbx_source_cmd_add "cmd1" "echo '[1,2,3]'"

  jq '.[0]' "$cmdsrc" | nbx_save_slot "s1"
  nbx_push_history "$cmdsrc" ".[0]" "s1" "query"

  nbx_ipynb_save "$nb"

  # Command + snapshot both stored for the command source.
  run jq -r '.metadata.nbx.command_sources[] | select(.label=="cmd1") | .command' "$nb"
  assert_output "echo '[1,2,3]'"
  run jq -rc '.metadata.nbx.command_sources[] | select(.label=="cmd1") | .snapshot' "$nb"
  assert_output "[1,2,3]"

  # Real file source stays; captured temppaths are filtered out of sources.
  run jq -c '.metadata.nbx.sources' "$nb"
  assert_output "[\"$filesrc\"]"
}

@test "nbx_ipynb_restore_command_sources restores the snapshot without running shell" {
  local nb="$NBX_DIR/test.ipynb"
  _create_test_notebook "$nb" "[]"
  # A stale command paired with a snapshot: restore must use the snapshot, not run the command.
  jq '.metadata.nbx.command_sources = [
        {"label":"cmd1","command":"echo [999]","snapshot":"[7,8,9]"}
      ]' "$nb" > "$nb.tmp"
  mv "$nb.tmp" "$nb"

  NBX_FILES=()
  nbx_ipynb_restore_command_sources "$nb"

  # Snapshot restored verbatim — command NOT executed.
  run jq -c '.' "$NBX_DIR/sources/cmd1"
  assert_output "[7,8,9]"

  # Rebuilt source registered and its command re-recorded for refresh.
  printf '%s\n' "${NBX_FILES[@]}" > "$NBX_DIR/_files.txt"
  run grep -c 'sources/cmd1' "$NBX_DIR/_files.txt"
  assert_output "1"
  run nbx_source_cmd_get "cmd1"
  assert_output "echo [999]"
}

@test "nbx_ipynb_restore_command_sources is a no-op without command sources" {
  local nb="$NBX_DIR/test.ipynb"
  _create_test_notebook "$nb" "[]"
  NBX_FILES=()
  run nbx_ipynb_restore_command_sources "$nb"
  assert_success
  assert [ ! -f "$NBX_DIR/sources/cmd1" ]
}

@test "nbx_ipynb save/load round-trip preserves a command source" {
  local nb="$NBX_DIR/test.ipynb"
  mkdir -p "$NBX_DIR/sources"
  echo '[{"n":1},{"n":2}]' > "$NBX_DIR/sources/cmd1"
  NBX_FILES=("$NBX_DIR/sources/cmd1")
  # A realistic command: spaces, quotes, brackets, a pipe.
  local cmd='gh api "/user/repos?per_page=100" | jq ".[]"'
  nbx_source_cmd_add "cmd1" "$cmd"
  jq '.[0]' "$NBX_DIR/sources/cmd1" | nbx_save_slot "s1"
  nbx_push_history "$NBX_DIR/sources/cmd1" ".[0]" "s1" "query"
  nbx_ipynb_save "$nb"

  # Fresh session — new NBX_DIR, reload from the notebook alone.
  local reloaded; reloaded=$(mktemp -d)
  NBX_DIR="$reloaded"; NBX_FILES=(); nbx_init_state
  nbx_ipynb_load "$nb" >/dev/null 2>&1

  run jq -c '.' "$NBX_DIR/sources/cmd1"
  assert_output '[{"n":1},{"n":2}]'
  run jq -c '.' "$NBX_DIR/slots/s1.json"
  assert_output '{"n":1}'
  # The command survived intact through save + reload (spaces, quotes, pipe).
  run nbx_source_cmd_get "cmd1"
  assert_output "$cmd"
  rm -rf "$reloaded"
}

@test "nbx_ipynb file source is fully portable — reload without the file" {
  local nb="$NBX_DIR/test.ipynb"
  local src="$NBX_DIR/users.json"
  echo '[{"name":"alice"},{"name":"bob"}]' > "$src"
  NBX_FILES=("$src")
  jq '[.[].name]' "$src" | nbx_save_slot "names"
  nbx_push_history "$src" '[.[].name]' "names" "query"
  nbx_ipynb_save "$nb"

  # The file's raw content is snapshotted into the notebook (command: null).
  run jq -rc '.metadata.nbx.command_sources[] | select(.label=="users.json") | .snapshot' "$nb"
  assert_output '[{"name":"alice"},{"name":"bob"}]'
  run jq -r '.metadata.nbx.command_sources[] | select(.label=="users.json") | .command' "$nb"
  assert_output "null"

  # Fresh session with the original file GONE.
  rm "$src"
  local reloaded; reloaded=$(mktemp -d)
  NBX_DIR="$reloaded"; NBX_FILES=(); nbx_init_state
  nbx_ipynb_load "$nb" >/dev/null 2>&1

  # Slot restored, and the source is rebuilt from the snapshot — re-queryable,
  # not just viewable.
  run jq -c '.' "$NBX_DIR/slots/names.json"
  assert_output '["alice","bob"]'
  run jq -c '.' "$NBX_DIR/sources/users.json"
  assert_output '[{"name":"alice"},{"name":"bob"}]'
  nbx_exec_jq '.[1].name' "$NBX_DIR/sources/users.json" "reQ"
  run jq -r '.' "$NBX_DIR/slots/reQ.json"
  assert_output "bob"
  rm -rf "$reloaded"
}
