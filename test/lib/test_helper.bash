#!/usr/bin/env bash
# Shared setup for all nbx tests — sources all libs and initializes state

source "$PROJECT_ROOT/lib/lib-state.bash"
source "$PROJECT_ROOT/lib/lib-display.bash"
source "$PROJECT_ROOT/lib/lib-jq.bash"
source "$PROJECT_ROOT/lib/lib-fzf.bash"
source "$PROJECT_ROOT/lib/lib-ipynb.bash"
source "$PROJECT_ROOT/lib/lib-bulk.bash"
source "$PROJECT_ROOT/lib/lib-deps.bash"
source "$PROJECT_ROOT/lib/lib-repl.bash"

LIB_DIR="$PROJECT_ROOT/lib"
NBX_DIR="$(mktemp -d)"
export NBX_DIR
NBX_NOTEBOOK=""
NBX_DIRTY=false
NBX_FILES=()

nbx_init_state

# Create a minimal valid .ipynb with given cells JSON
# Usage: _create_test_notebook "$outfile" "$cells_json"
_create_test_notebook() {
  local outfile="$1" cells_json="${2:-[]}"
  jq -n --argjson cells "$cells_json" '{
    nbformat: 4, nbformat_minor: 5,
    metadata: {nbx: {version: "0.1", sources: []}, kernelspec: {name: "bash"}},
    cells: $cells
  }' > "$outfile"
}
