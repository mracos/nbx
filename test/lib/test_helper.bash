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

# --- Tabular sources (ADR 0009) ---

# CSV/TSV support shells out to mlr, which CI does not have and which these
# tests are not trying to verify: what matters is that nbx routes the file
# through it. The stub records its argv in $STUB_MLR_ARGV and emits the JSON a
# real conversion would.
# Usage: _stub_mlr [json]
_stub_mlr() {
  local json="$1"
  # Not a ${1:-default}: bash ends that expansion at the first '}' in the
  # default, which a JSON literal is full of.
  [[ -n "$json" ]] || json='[{"name":"ana","age":31}]'
  local bin="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$bin"
  {
    echo '#!/usr/bin/env bash'
    echo 'printf "%s\n" "$*" > "$STUB_MLR_ARGV"'
    printf 'cat <<%s\n%s\nJSON\n' "'JSON'" "$json"
  } > "$bin/mlr"
  chmod +x "$bin/mlr"
  export STUB_MLR_ARGV="$BATS_TEST_TMPDIR/mlr-argv"
  export PATH="$bin:$PATH"
}

# $PATH minus every directory that holds an mlr, so the missing-dependency path
# is exercised on a machine that does have miller. Dropping the whole PATH
# instead would break realpath/mkdir and test nothing.
_path_without_mlr() {
  local d out=()
  local IFS=:
  for d in $PATH; do
    [[ -x "$d/mlr" ]] && continue
    out+=("$d")
  done
  printf '%s' "${out[*]}"
}
