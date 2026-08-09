#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# --- Preview script regression ---

@test "preview script runs without errors on valid query" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice","age":30}]' > "$src"

  # Simulate what nbx_fzf_query does: write query file + preview script
  local query_file="$NBX_DIR/.query"
  echo '.[] | .name' > "$query_file"

  local lib_dir="$PROJECT_ROOT/lib"
  local preview_script="$NBX_DIR/.preview.sh"
  cat > "$preview_script" <<PREVIEW_EOF
#!/usr/bin/env bash
query=\$(cat '$query_file')
args=()
unwrap=""
for f in "$NBX_DIR/slots"/*.json; do
  [ -f "\$f" ] || continue
  name=\$(basename "\$f" .json)
  args+=(--slurpfile "\$name" "\$f")
  unwrap+="(\\\$\${name}[0]) as \\\$\${name} | "
done
err_file="$NBX_DIR/.preview_err"
result=\$(jq -C "\${args[@]}" "\${unwrap}\${query}" '$src' 2>"\$err_file" | head -200)
if [ -n "\$result" ]; then
  echo "\$result"
elif [ -s "\$err_file" ]; then
  echo 'invalid'
else
  echo 'empty'
fi
PREVIEW_EOF
  chmod +x "$preview_script"

  run bash "$preview_script"
  assert_success
  assert_output --partial "alice"
}

@test "preview script shows fallback on invalid query" {
  local src="$NBX_DIR/data.json"
  echo '{"x":1}' > "$src"

  local query_file="$NBX_DIR/.query"
  echo 'INVALID QUERY |||' > "$query_file"

  local preview_script="$NBX_DIR/.preview.sh"
  cat > "$preview_script" <<PREVIEW_EOF
#!/usr/bin/env bash
query=\$(cat '$query_file')
args=()
for f in "$NBX_DIR/slots"/*.json; do
  [ -f "\$f" ] || continue
  name=\$(basename "\$f" .json)
  val=\$(jq -c '.' "\$f" 2>/dev/null)
  [ -n "\$val" ] && args+=(--argjson "\$name" "\$val")
done
result=\$(jq -C "\${args[@]}" "\$query" '$src' 2>&1 | head -200)
if [ -n "\$result" ] && ! echo "\$result" | head -1 | grep -q '^jq:'; then
  echo "\$result"
else
  echo 'invalid'
  jq -C '.' '$src' 2>/dev/null | head -50
fi
PREVIEW_EOF
  chmod +x "$preview_script"

  run bash "$preview_script"
  assert_success
  assert_output --partial "invalid"
}

@test "preview script works with slot injection" {
  local src="$NBX_DIR/data.json"
  echo '[{"name":"alice","age":30},{"name":"bob","age":25}]' > "$src"
  echo '28' | nbx_save_slot "threshold"

  local query_file="$NBX_DIR/.query"
  echo '[.[] | select(.age > $threshold)]' > "$query_file"

  local preview_script="$NBX_DIR/.preview.sh"
  cat > "$preview_script" <<PREVIEW_EOF
#!/usr/bin/env bash
query=\$(cat '$query_file')
args=()
unwrap=""
for f in "$NBX_DIR/slots"/*.json; do
  [ -f "\$f" ] || continue
  name=\$(basename "\$f" .json)
  args+=(--slurpfile "\$name" "\$f")
  unwrap+="(\\\$\${name}[0]) as \\\$\${name} | "
done
err_file="$NBX_DIR/.preview_err"
result=\$(jq -C "\${args[@]}" "\${unwrap}\${query}" '$src' 2>"\$err_file" | head -200)
if [ -n "\$result" ]; then
  echo "\$result"
elif [ -s "\$err_file" ]; then
  echo 'invalid'
else
  echo 'empty'
fi
PREVIEW_EOF
  chmod +x "$preview_script"

  run bash "$preview_script"
  assert_success
  assert_output --partial "alice"
  refute_output --partial "bob"
}

# --- Slot suggestions in fzf query ---

@test "fzf suggestions include slot names as \$var" {
  run bash -c '
    NBX_DIR=$(mktemp -d)
    source "'"$PROJECT_ROOT"'/lib/lib-state.bash"
    source "'"$PROJECT_ROOT"'/lib/lib-jq.bash"
    nbx_init_state
    echo "[1,2,3]" > "$NBX_DIR/slots/mydata.json"
    echo "\"hello\"" > "$NBX_DIR/slots/greeting.json"

    # Simulate what nbx_fzf_query does: build suggestions file
    suggestions_file="$NBX_DIR/.suggestions"
    : > "$suggestions_file"
    for slot_name in $(nbx_list_slots); do
      echo "\$${slot_name}" >> "$suggestions_file"
    done
    cat "$suggestions_file"
  '
  assert_success
  assert_output --partial '$greeting'
  assert_output --partial '$mydata'
}

# --- Preview full mode ---

@test "preview script respects full mode for large output" {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/slots"

  jq -n '[range(300) | {id: ., name: "item-\(.)"}]' > "$tmpdir/input.json"
  echo '.' > "$tmpdir/.query"

  cat > "$tmpdir/.preview.sh" <<'PREVIEW_EOF'
#!/usr/bin/env bash
query_file="$1"; input_file="$2"; slots_dir="$3"
err_file="${slots_dir%/slots}/.preview_err"
query=$(cat "$query_file"); full_mode="${4:-}"
args=(); unwrap=""
for f in "$slots_dir"/*.json; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .json); name="${name#\$}"
  args+=(--slurpfile "$name" "$f")
  unwrap+="(\$${name}[0]) as \$${name} | "
done
limit="head -200"
[ "$full_mode" = "full" ] && limit="cat"
jq "${args[@]}" "${unwrap}${query}" "$input_file" 2>"$err_file" | $limit
PREVIEW_EOF
  chmod +x "$tmpdir/.preview.sh"

  run bash "$tmpdir/.preview.sh" "$tmpdir/.query" "$tmpdir/input.json" "$tmpdir/slots"
  assert_success
  local normal_lines
  normal_lines=$(echo "$output" | wc -l | tr -d ' ')
  assert [ "$normal_lines" -le 200 ]

  run bash "$tmpdir/.preview.sh" "$tmpdir/.query" "$tmpdir/input.json" "$tmpdir/slots" full
  assert_success
  local full_lines
  full_lines=$(echo "$output" | wc -l | tr -d ' ')
  assert [ "$full_lines" -gt 200 ]

  rm -rf "$tmpdir"
}

# --- Context label ---

@test "nbx_fzf_query accepts context_label parameter" {
  run bash -c '
    source "'"$PROJECT_ROOT"'/lib/lib-state.bash"
    source "'"$PROJECT_ROOT"'/lib/lib-fzf.bash"
    declare -f nbx_fzf_query | grep -q "context_label"
  '
  assert_success
}

# --- Tab completion binding ---

@test "tab binding delegates to a script, not an inline case" {
  # fzf's transform(...) parser matches on balanced parens; an inline case
  # (with '[S'*) / *) patterns) closes the action early and fzf errors with
  # "unknown action: refresh-preview...". The logic must live in a helper script.
  run bash -c '
    source "'"$PROJECT_ROOT"'/lib/lib-fzf.bash"
    declare -f nbx_fzf_query
  '
  assert_success
  assert_output --partial 'tab:transform(bash '"'"'$tab_script'"'"' {})'
  refute_output --partial 'tab:transform(case'
}

@test "tab helper completes a stash line into a change-query action" {
  local tab_script="$NBX_DIR/.tab.sh"
  cat > "$tab_script" <<'TAB_EOF'
#!/usr/bin/env bash
line="$1"
case "$line" in
  '[S'*)
    q=$(printf '%s' "$line" | sed 's/^\[S[0-9]*\] //; s/  [0-9].*//')
    echo "change-query($q)+refresh-preview"
    ;;
  *)
    echo "replace-query"
    ;;
esac
TAB_EOF

  run bash "$tab_script" '[S1] .items[] | .name  42 array'
  assert_success
  assert_output 'change-query(.items[] | .name)+refresh-preview'

  run bash "$tab_script" '.foo.bar'
  assert_success
  assert_output 'replace-query'
}

# --- Pick index filter ---

@test "_nbx_pick_indices_to_filter single selection produces unwrapped index" {
  local result
  result=$(echo '3:{"name":"bob"}' | _nbx_pick_indices_to_filter)
  assert_equal ".[3]" "$result"
}

@test "_nbx_pick_indices_to_filter multiple selections produces array" {
  local result
  result=$(printf '0:{"a":1}\n2:{"b":2}\n' | _nbx_pick_indices_to_filter)
  assert_equal "[.[0], .[2]]" "$result"
}

