#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# --- Bulk replay ---

@test "nbx_bulk_replay executes steps from file" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice","age":30},{"name":"bob","age":25}]' > "$src"
  NBX_FILES=("$src")

  local bulk_file="$NBX_DIR/.bulk"
  cat > "$bulk_file" <<EOF
# This is a comment
input -> 28 -> \$threshold
data.json -> [.[] | select(.age > \$threshold)] -> \$result
EOF

  run nbx_bulk_replay "$bulk_file"
  assert_success
  assert_output --partial "Bulk: 2 ok, 0 failed"

  run nbx_history_depth
  assert_output "2"

  run jq '.' "$NBX_DIR/slots/threshold.json"
  assert_output "28"

  run jq -c '.[].name' "$NBX_DIR/slots/result.json"
  assert_output '"alice"'
}

@test "nbx_bulk_replay strips [N] prefix and metadata suffix" {
  local src="$NBX_DIR/data.json"
  echo '[{"x":1},{"x":2}]' > "$src"
  NBX_FILES=("$src")

  local bulk_file="$NBX_DIR/.bulk"
  cat > "$bulk_file" <<EOF
  [1] data.json -> .[0]  1 object -> \$first
EOF

  run nbx_bulk_replay "$bulk_file"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/first.json"
  assert_output '{"x":1}'
}

@test "nbx_bulk_replay skips comments and empty lines" {
  local src="$NBX_DIR/data.json"
  echo '{"x":1}' > "$src"
  NBX_FILES=("$src")

  local bulk_file="$NBX_DIR/.bulk"
  cat > "$bulk_file" <<EOF
# comment
# another comment

data.json -> . -> \$out

# trailing comment
EOF

  run nbx_bulk_replay "$bulk_file"
  assert_success
  assert_output --partial "Bulk: 1 ok, 0 failed"
}

@test "nbx_bulk_replay handles slot references as source" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice"},{"name":"bob"}]' > "$src"
  NBX_FILES=("$src")

  local bulk_file="$NBX_DIR/.bulk"
  cat > "$bulk_file" <<EOF
data.json -> . -> \$all
\$all -> .[0] -> \$first
EOF

  run nbx_bulk_replay "$bulk_file"
  assert_success
  assert_output --partial "Bulk: 2 ok, 0 failed"

  run jq -c '.' "$NBX_DIR/slots/first.json"
  assert_output '{"name":"alice"}'
}

@test "nbx_bulk_replay reports failures for missing sources" {
  NBX_FILES=()

  local bulk_file="$NBX_DIR/.bulk"
  cat > "$bulk_file" <<EOF
nonexistent.json -> . -> \$out
EOF

  run nbx_bulk_replay "$bulk_file"
  assert_failure
  assert_output --partial "Source not found"
  assert_output --partial "0 ok, 1 failed"
}

@test "nbx_bulk_replay rolls back on failure" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice"},{"name":"bob"}]' > "$src"
  NBX_FILES=("$src")

  # Set up pre-existing state
  echo '{"pre":"existing"}' > "$NBX_DIR/slots/before.json"
  printf '%s\t%s\t%s\t%s\n' "$src" "." "before" "query" > "$NBX_DIR/history/1"

  local bulk_file="$NBX_DIR/.bulk"
  cat > "$bulk_file" <<EOF
data.json -> . -> \$all
data.json -> .nonexistent | error -> \$boom
EOF

  run nbx_bulk_replay "$bulk_file"
  assert_failure
  assert_output --partial "Rolled back"
  assert_output --partial "1 ok, 1 failed"

  # Pre-existing state should be restored
  run jq -c '.' "$NBX_DIR/slots/before.json"
  assert_output '{"pre":"existing"}'

  run nbx_history_depth
  assert_output "1"

  # The slot from the successful step should NOT exist (rolled back)
  [ ! -f "$NBX_DIR/slots/all.json" ]
}

@test "nbx_bulk_replay shows jq error on filter failure" {
  local src="$NBX_DIR/data.json"
  echo '{}' > "$src"
  NBX_FILES=("$src")

  local bulk_file="$NBX_DIR/.bulk"
  cat > "$bulk_file" <<EOF
data.json -> .[] | invalid_func -> \$out
EOF

  run nbx_bulk_replay "$bulk_file"
  assert_failure
  assert_output --partial "Filter failed"
  # jq error message should be visible (not swallowed)
  assert_output --partial "jq:"
}

# --- Pick steps as normal queries ---

@test "nbx_bulk_replay executes pick index filter" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice"},{"name":"bob"},{"name":"charlie"}]' > "$src"
  NBX_FILES=("$src")

  cat > "$NBX_DIR/.bulk" <<EOF
data.json -> . -> \$all
\$all -> [.[0], .[2]] -> \$picked
EOF

  run nbx_bulk_replay "$NBX_DIR/.bulk"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/picked.json"
  assert_output '[{"name":"alice"},{"name":"charlie"}]'

  run nbx_history_depth
  assert_output "2"
}

@test "nbx_bulk_replay converts a CSV path written by hand" {
  _stub_mlr '[{"name":"ana","age":31},{"name":"bruno","age":25}]'
  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name,age\nana,31\nbruno,25\n' > "$csv"
  NBX_FILES=()

  local bulk_file="$NBX_DIR/.bulk"
  cat > "$bulk_file" <<EOF
$csv -> [.[] | select(.age > 30) | .name] -> \$grown
EOF

  run nbx_bulk_replay "$bulk_file"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/grown.json"
  assert_output '["ana"]'
}

@test "nbx_bulk_replay fails the step when a CSV cannot be converted" {
  local csv="$BATS_TEST_TMPDIR/users.csv"
  printf 'name,age\nana,31\n' > "$csv"
  NBX_FILES=()

  local bulk_file="$NBX_DIR/.bulk"
  cat > "$bulk_file" <<EOF
$csv -> . -> \$rows
EOF

  PATH="$(_path_without_mlr)" run nbx_bulk_replay "$bulk_file"
  assert_output --partial "miller"
  assert_output --partial "0 ok, 1 failed"
}
