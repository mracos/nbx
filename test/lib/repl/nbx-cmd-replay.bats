#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

# Helper: create a 3-step pipeline with real data for replay
# [1] data.json → .[] → $users  (external file)
# [2] $users → [.[].name] → $names  (depends on users)
# [3] $users → [.[].age] → $ages  (depends on users)
_setup_replay_pipeline() {
  local data_file="$NBX_DIR/data.json"
  echo '[{"name":"alice","age":30},{"name":"bob","age":25}]' > "$data_file"

  # Step 1: query external file
  jq '.[]' "$data_file" | nbx_save_slot "users"
  nbx_push_history "$data_file" ".[]" "users" "query"

  # Step 2: query $users for names
  nbx_jq_with_slots '[.[].name]' "$NBX_DIR/slots/users.json" | nbx_save_slot "names"
  nbx_push_history "$NBX_DIR/slots/users.json" '[.[].name]' "names" "query"

  # Step 3: query $users for ages
  nbx_jq_with_slots '[.[].age]' "$NBX_DIR/slots/users.json" | nbx_save_slot "ages"
  nbx_push_history "$NBX_DIR/slots/users.json" '[.[].age]' "ages" "query"
}

# --- Basic replay ---

@test "replay single step re-executes and updates slot" {
  _setup_replay_pipeline

  # Manually corrupt the names slot
  echo '["WRONG"]' > "$NBX_DIR/slots/names.json"

  run nbx_cmd_replay 2
  assert_success

  run jq -c '.' "$NBX_DIR/slots/names.json"
  assert_output '["alice","bob"]'
}

@test "replay single step auto-replays stale dependents" {
  _setup_replay_pipeline

  # Add step 4 that depends on $names
  nbx_jq_with_slots '.[0]' "$NBX_DIR/slots/names.json" | nbx_save_slot "first_name"
  nbx_push_history "$NBX_DIR/slots/names.json" '.[0]' "first_name" "query"

  # Corrupt step 4 to verify it gets re-replayed
  echo '"WRONG"' > "$NBX_DIR/slots/first_name.json"

  nbx_cmd_replay 2

  # Auto-replay should have updated step 4
  run jq -r '.' "$NBX_DIR/slots/first_name.json"
  assert_output "alice"
}

@test "replay clears stale mark on replayed step" {
  _setup_replay_pipeline
  nbx_mark_stale 2

  nbx_cmd_replay 2

  run nbx_is_stale 2
  assert_failure
}

@test "replay missing step fails" {
  run nbx_cmd_replay 99
  assert_failure
  assert_output --partial "not found"
}

@test "replay with no args defaults to --stale" {
  _setup_replay_pipeline
  nbx_mark_stale 2
  echo '["WRONG"]' > "$NBX_DIR/slots/names.json"

  run nbx_cmd_replay ""
  assert_success

  run jq -c '.' "$NBX_DIR/slots/names.json"
  assert_output '["alice","bob"]'
}

@test "replay with no args and nothing stale is no-op" {
  _setup_replay_pipeline

  run nbx_cmd_replay ""
  assert_success
  assert_output --partial "Nothing stale"
}

# --- replay --stale ---

@test "replay --stale replays all stale steps in order" {
  _setup_replay_pipeline

  # Mark steps 2 and 3 stale and corrupt their data
  nbx_mark_stale 2
  nbx_mark_stale 3
  echo '["WRONG"]' > "$NBX_DIR/slots/names.json"
  echo '[0,0]' > "$NBX_DIR/slots/ages.json"

  run nbx_cmd_replay "--stale"
  assert_success

  # Verify data was re-computed
  run jq -c '.' "$NBX_DIR/slots/names.json"
  assert_output '["alice","bob"]'
  run jq -c '.' "$NBX_DIR/slots/ages.json"
  assert_output '[30,25]'

  # Verify stale marks cleared
  run nbx_is_stale 2
  assert_failure
  run nbx_is_stale 3
  assert_failure
}

@test "replay --stale with nothing stale is no-op" {
  _setup_replay_pipeline

  run nbx_cmd_replay "--stale"
  assert_success
  assert_output --partial "Nothing stale"
}

# --- replay --from N ---

@test "replay --from replays step and all dependents" {
  _setup_replay_pipeline

  # Modify source data (keep same structure — array of objects)
  echo '[{"name":"charlie","age":40},{"name":"diana","age":35}]' > "$NBX_DIR/data.json"

  run nbx_cmd_replay "--from 1"
  assert_success

  # All slots should reflect new data
  run jq -c '.' "$NBX_DIR/slots/names.json"
  assert_output '["charlie","diana"]'
  run jq -c '.' "$NBX_DIR/slots/ages.json"
  assert_output '[40,35]'
}

@test "replay --from on leaf step replays only that step" {
  _setup_replay_pipeline

  echo '["WRONG"]' > "$NBX_DIR/slots/ages.json"

  run nbx_cmd_replay "--from 3"
  assert_success

  run jq -c '.' "$NBX_DIR/slots/ages.json"
  assert_output '[30,25]'
}

# --- Pick replay ---

@test "replay re-applies pick index filter" {
  local data_file="$NBX_DIR/data.json"
  echo '[{"name":"alice"},{"name":"bob"},{"name":"charlie"}]' > "$data_file"

  # Step 1: load data
  jq '.' "$data_file" | nbx_save_slot "people"
  nbx_push_history "$data_file" "." "people" "query"

  # Step 2: pick indices 0 and 2
  jq '[.[0], .[2]]' "$NBX_DIR/slots/people.json" | nbx_save_slot "selected"
  nbx_push_history "$NBX_DIR/slots/people.json" '[.[0], .[2]]' "selected" "pick"

  # Corrupt the pick result
  echo '[]' > "$NBX_DIR/slots/selected.json"

  nbx_cmd_replay 2

  run jq -c '.' "$NBX_DIR/slots/selected.json"
  assert_output '[{"name":"alice"},{"name":"charlie"}]'
}

# --- Hidden steps participate in replay ---

@test "replay --stale replays hidden steps" {
  _setup_replay_pipeline

  # Hide step 2 and mark it stale
  nbx_toggle_hidden 2
  nbx_mark_stale 2
  echo '["WRONG"]' > "$NBX_DIR/slots/names.json"

  run nbx_cmd_replay "--stale"
  assert_success

  # Hidden step was still replayed
  run jq -c '.' "$NBX_DIR/slots/names.json"
  assert_output '["alice","bob"]'
  run nbx_is_stale 2
  assert_failure
}

@test "edit propagates staleness to hidden dependents" {
  # Step 1: input
  echo '"30"' | nbx_save_slot "threshold"
  nbx_push_history "input" "30" "threshold" "input"

  # Step 2: depends on threshold, hidden
  echo '[]' | nbx_save_slot "filtered"
  nbx_push_history "$NBX_DIR/slots/threshold.json" '.[] | select(.age > 30)' "filtered" "query"
  nbx_toggle_hidden 2

  # Edit step 1
  echo "40" | nbx_cmd_edit 1

  # Hidden step 2 should still be marked stale
  run nbx_is_stale 2
  assert_success
}

# --- Input step replay ---

@test "replay on input step is no-op" {
  echo '"hello"' | nbx_save_slot "greeting"
  nbx_push_history "input" "hello" "greeting" "input"

  run nbx_cmd_replay 1
  assert_success

  run jq -r '.' "$NBX_DIR/slots/greeting.json"
  assert_output "hello"
}

# --- Failed step tracking ---

@test "replay marks step as failed when jq has errors" {
  local data_file="$NBX_DIR/data.json"
  echo '[{"name":"alice"}, "bad_string", {"name":"bob"}]' > "$data_file"

  jq '.' "$data_file" | nbx_save_slot "items"
  nbx_push_history "$data_file" "." "items" "query"

  # Step 2: query that will fail on the string element
  echo '[]' | nbx_save_slot "names"
  nbx_push_history "$NBX_DIR/slots/items.json" '[.[] | .name]' "names" "query"

  nbx_mark_stale 2

  run nbx_cmd_replay "--stale"

  run nbx_is_failed 2
  assert_success
}

@test "replay stores error message for failed step" {
  local data_file="$NBX_DIR/data.json"
  echo '[{"name":"alice"}, "bad_string"]' > "$data_file"

  jq '.' "$data_file" | nbx_save_slot "items"
  nbx_push_history "$data_file" "." "items" "query"

  echo '[]' | nbx_save_slot "names"
  nbx_push_history "$NBX_DIR/slots/items.json" '[.[] | .name]' "names" "query"

  nbx_mark_stale 2
  nbx_cmd_replay "--stale"

  run nbx_failed_error 2
  assert_success
  assert_output --partial "string"
}

@test "replay clears failed mark on successful re-replay" {
  _setup_replay_pipeline
  nbx_mark_failed 2
  mkdir -p "$NBX_DIR/.failed_err"
  echo "old error" > "$NBX_DIR/.failed_err/2"

  nbx_mark_stale 2
  nbx_cmd_replay "--stale"

  run nbx_is_failed 2
  assert_failure
}

@test "replay --stale reports failed steps in output" {
  local data_file="$NBX_DIR/data.json"
  echo '[{"name":"alice"}, "bad"]' > "$data_file"

  jq '.' "$data_file" | nbx_save_slot "items"
  nbx_push_history "$data_file" "." "items" "query"

  echo '[]' | nbx_save_slot "names"
  nbx_push_history "$NBX_DIR/slots/items.json" '[.[] | .name]' "names" "query"

  nbx_mark_stale 2

  run nbx_cmd_replay "--stale"
  assert_output --partial "Failed"
  assert_output --partial "1 failed"
}
