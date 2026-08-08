#!/usr/bin/env bats
# bats file_tags=unit
# Tests for edit's focus mode (query/pipe steps with pinned slot)

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "edit auto-pins last step when nothing pinned" {
  echo '[1,2,3]' > "$NBX_DIR/data.json"
  _create_test_step "s1" '[1,2,3]' "$NBX_DIR/data.json" "." "query"
  _create_test_step "s2" '[1,2,3]' "$NBX_DIR/slots/s1.json" "." "query"

  # Stub: first call returns query, second call cancels
  echo "0" > "$NBX_DIR/.call_count"
  nbx_fzf_focus() {
    local n=$(<"$NBX_DIR/.call_count")
    echo "$((n + 1))" > "$NBX_DIR/.call_count"
    [[ $n -eq 0 ]] && echo "." || return 1
  }

  nbx_cmd_edit "1"

  run nbx_pinned_slot
  assert_output "s2"
}

@test "edit requires a step number" {
  run nbx_cmd_edit ""
  assert_failure
  assert_output --partial "Usage"
}

@test "edit rejects missing step" {
  run nbx_cmd_edit "99"
  assert_failure
  assert_output --partial "not found"
}

@test "edit focus rejects input type steps with pin" {
  _create_test_step "threshold" "30" "input" "30" "input"
  _create_test_step "s2" '[1]' "$NBX_DIR/slots/threshold.json" "." "query"
  nbx_pin "s2"

  # Input steps go through inline edit, not focus — stub read to cancel
  run bash -c "echo '' | NBX_DIR='$NBX_DIR' PROJECT_ROOT='$PROJECT_ROOT' source '$PROJECT_ROOT/test/test_helper'; source '$PROJECT_ROOT/test/lib/repl/test_helper'; nbx_cmd_edit 1"
  # Should not error about input steps — it handles them inline
}

@test "edit applies edit on enter and loops when pinned" {
  echo '[1,2,3]' > "$NBX_DIR/data.json"
  _create_test_step "s1" '[1,2,3]' "$NBX_DIR/data.json" "." "query"
  _create_test_step "s2" '[1,2,3]' "$NBX_DIR/slots/s1.json" "." "query"
  nbx_pin "s2"

  echo "0" > "$NBX_DIR/.call_count"
  nbx_fzf_focus() {
    local n=$(<"$NBX_DIR/.call_count")
    echo "$((n + 1))" > "$NBX_DIR/.call_count"
    [[ $n -eq 0 ]] && echo ".[:2]" || return 1
  }

  nbx_cmd_edit "1"

  run jq -c '.' "$NBX_DIR/slots/s1.json"
  assert_output '[1,2]'
  run cut -f2 "$NBX_DIR/history/1"
  assert_output '.[:2]'
}

@test "edit restores backup on cancel when pinned" {
  echo '[1,2,3]' > "$NBX_DIR/data.json"
  _create_test_step "s1" '[1,2,3]' "$NBX_DIR/data.json" "." "query"
  _create_test_step "s2" '[1,2,3]' "$NBX_DIR/slots/s1.json" "." "query"
  nbx_pin "s2"

  # Cancel immediately
  nbx_fzf_focus() { return 1; }

  nbx_cmd_edit "1"

  # Original data preserved
  run jq -c '.' "$NBX_DIR/slots/s1.json"
  assert_output '[1,2,3]'
}

@test "edit SWITCH signal switches to new step" {
  echo '[1,2,3]' > "$NBX_DIR/data.json"
  _create_test_step "s1" '[1,2,3]' "$NBX_DIR/data.json" "." "query"
  echo '[1,2,3]' | nbx_save_slot "s2"
  nbx_push_history "$NBX_DIR/slots/s1.json" "." "s2" "query"
  nbx_pin "s2"

  echo "0" > "$NBX_DIR/.call_count"
  nbx_fzf_focus() {
    local n=$(<"$NBX_DIR/.call_count")
    echo "$((n + 1))" > "$NBX_DIR/.call_count"
    [[ $n -eq 0 ]] && echo "SWITCH:.[:2]" || return 1
  }
  _nbx_pick_edit_step() { echo "2"; }

  nbx_cmd_edit "1"

  run jq -c '.' "$NBX_DIR/slots/s1.json"
  assert_output '[1,2]'
}

@test "edit auto-replays stale steps when pinned" {
  echo '[1,2,3]' > "$NBX_DIR/data.json"
  _create_test_step "s1" '[1,2,3]' "$NBX_DIR/data.json" "." "query"
  echo '[1,2,3]' | nbx_save_slot "s2"
  nbx_push_history "$NBX_DIR/slots/s1.json" "." "s2" "query"
  _create_test_step "s3" '[1,2,3]' "$NBX_DIR/slots/s2.json" "." "query"
  nbx_pin "s3"

  echo "0" > "$NBX_DIR/.call_count"
  nbx_fzf_focus() {
    local n=$(<"$NBX_DIR/.call_count")
    echo "$((n + 1))" > "$NBX_DIR/.call_count"
    [[ $n -eq 0 ]] && echo ".[:2]" || return 1
  }

  nbx_cmd_edit "1"

  local stale_count
  stale_count=$(nbx_stale_steps | grep -c . || true)
  assert_equal "$stale_count" "0"
}

@test "edit focus preview script generates both sections" {
  echo '[{"a":1},{"a":2}]' > "$NBX_DIR/data.json"
  _create_test_step "s1" '[{"a":1},{"a":2}]' "$NBX_DIR/data.json" "." "query"
  echo '[{"a":1},{"a":2}]' | nbx_save_slot "s2"
  nbx_push_history "$NBX_DIR/slots/s1.json" "." "s2" "query"

  local lib_dir="$PROJECT_ROOT/lib"
  echo '.' > "$NBX_DIR/.query"
  nbx_pin "s2"

  local preview_script="$NBX_DIR/.test_preview.sh"
  cat > "$preview_script" <<'PREVIEW_EOF'
#!/usr/bin/env bash
query_file="$1"; input_file="$2"; slots_dir="$3"; lib_dir="$4"
editing_slot="$5"; pinned_slot="$6"
NBX_DIR="${slots_dir%/slots}"; export NBX_DIR
source "$lib_dir/lib-state.bash"
source "$lib_dir/lib-jq.bash"
source "$lib_dir/lib-display.bash"
source "$lib_dir/lib-deps.bash"
query=$(cat "$query_file")
nbx_build_slot_args
result=$(jq "${NBX_JQ_ARGS[@]}" "${NBX_JQ_UNWRAP}${query}" "$input_file" 2>/dev/null | head -80)
[ -n "$result" ] && echo "EDITING_RESULT"
pinned_file="$slots_dir/${pinned_slot}.json"
[ -f "$pinned_file" ] && echo "PINNED_RESULT"
PREVIEW_EOF
  chmod +x "$preview_script"

  run bash "$preview_script" "$NBX_DIR/.query" "$NBX_DIR/data.json" "$NBX_DIR/slots" "$lib_dir" "s1" "s2"
  assert_output --partial "EDITING_RESULT"
  assert_output --partial "PINNED_RESULT"
}
