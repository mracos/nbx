#!/usr/bin/env bats
# bats file_tags=unit

setup() {
  load "$PROJECT_ROOT/test/test_helper"
  load test_helper
}

teardown() {
  rm -rf "$NBX_DIR"
}

@test "nbx_cmd_save saves to notebook" {
  local src="$NBX_DIR/input.json"
  echo '{"x":1}' > "$src"
  NBX_FILES=("$src")
  _create_test_step "s1" '{"x":1}' "$src"
  NBX_NOTEBOOK="$NBX_DIR/test.ipynb"
  nbx_cmd_save ""
  assert [ -f "$NBX_DIR/test.ipynb" ]
  run jq '.cells | length' "$NBX_DIR/test.ipynb"
  assert_output "1"
  assert_equal "$NBX_DIRTY" "false"
}

@test "save and load preserves cell order with 10+ cells" {
  local src="$NBX_DIR/input.json"
  echo '[1,2,3,4,5,6,7,8,9,10,11,12]' > "$src"
  NBX_FILES=("$src")

  local i
  for i in $(seq 1 12); do
    _create_test_step "s$i" "{\"n\":$i}" "$src" ".[$((i - 1))]" "query"
  done

  NBX_NOTEBOOK="$NBX_DIR/test.ipynb"
  nbx_cmd_save ""

  # Load into fresh state and verify order
  nbx_reset
  nbx_ipynb_load "$NBX_DIR/test.ipynb"

  for i in $(seq 1 12); do
    local slot
    slot=$(nbx_history_field "$i" slot)
    assert_equal "$slot" "s$i" "cell $i should be s$i, got $slot"
  done
}

@test "nbx_cmd_save with name creates save-as" {
  local src="$NBX_DIR/input.json"
  echo '{"x":1}' > "$src"
  NBX_FILES=("$src")
  _create_test_step "s1" '{"x":1}' "$src"
  # save-as prepends pwd, so use just a filename
  nbx_cmd_save "other"
  assert [ -f "$(pwd)/other.ipynb" ]
  rm -f "$(pwd)/other.ipynb"
}
