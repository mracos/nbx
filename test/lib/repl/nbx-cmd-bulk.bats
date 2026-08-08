#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "bulk pre-fill writes pick steps as normal query lines" {
  _create_test_step "s1" '[1,2]' "data.json"
  _create_test_step "s2" '[1]' "$NBX_DIR/slots/s1.json" "[.[0]]" "pick"

  local tmpfile="$NBX_DIR/.bulk_edit"
  : > "$tmpfile"
  local depth
  depth=$(nbx_history_depth)
  local i
  for ((i = 1; i <= depth; i++)); do
    local entry input query slot type label
    entry=$(cat "$NBX_DIR/history/$i")
    input=$(cut -f1 <<< "$entry")
    query=$(cut -f2 <<< "$entry")
    slot=$(cut -f3 <<< "$entry")
    type=$(cut -f4 <<< "$entry")
    label=$(nbx_input_label "$input")
    echo "$label -> $query -> \$${slot#\$}" >> "$tmpfile"
  done

  run cat "$tmpfile"
  assert_output --partial '[.[0]] -> $s2'
  refute_output --partial "picked"
}

@test "bulk replay executes pick filter like a query" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice"},{"name":"bob"},{"name":"charlie"}]' > "$src"
  NBX_FILES=("$src")

  local bulk="$NBX_DIR/.bulk_edit"
  cat > "$bulk" <<'EOF'
data.json -> . -> $all
$all -> [.[0], .[2]] -> $picked
EOF

  run nbx_bulk_replay "$bulk"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/picked.json"
  assert_output '[{"name":"alice"},{"name":"charlie"}]'
}

@test "bulk replay single pick produces unwrapped value" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice"},{"name":"bob"}]' > "$src"
  NBX_FILES=("$src")

  local bulk="$NBX_DIR/.bulk_edit"
  cat > "$bulk" <<'EOF'
data.json -> .[1] -> $one
EOF

  run nbx_bulk_replay "$bulk"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/one.json"
  assert_output '{"name":"bob"}'
}
