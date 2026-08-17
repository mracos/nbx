#!/usr/bin/env bash
# nbx deps: dependency graph and staleness tracking

# --- Dependency graph ---

# Returns slot names that step N depends on (one per line).
# Sources: input field (slot file ref) + $slot_name references in query.
nbx_step_deps() {
  local step="$1"
  local entry
  entry=$(nbx_get_history "$step") || return 1
  local input query
  input=$(cut -f1 <<< "$entry")
  query=$(cut -f2 <<< "$entry")

  local deps=""

  # Source 1: input field references a slot file
  if [[ "$input" == "$NBX_DIR/slots/"* ]]; then
    local slot_name
    slot_name=$(basename "$input" .json)
    deps="$slot_name"
  fi

  # Source 2: $slot_name references in the query
  local s
  for s in $(nbx_list_slots); do
    [[ -z "$s" ]] && continue
    # Match $name as a word (not substring of another var)
    if [[ "$query" =~ \$${s}([^a-zA-Z0-9_]|$) ]]; then
      # Avoid duplicates with input-derived dep
      if [[ "$deps" != *"$s"* ]]; then
        deps=$(printf '%s\n%s' "$deps" "$s")
      fi
    fi
  done

  # Output non-empty lines
  echo "$deps" | while IFS= read -r line; do
    [[ -n "$line" ]] && echo "$line"
  done
}

# Returns the step number that produces the given slot name.
nbx_slot_to_step() {
  local slot_name="${1#\$}"
  local depth
  depth=$(nbx_history_depth)
  local i
  for ((i = 1; i <= depth; i++)); do
    local s
    s=$(cut -f3 "$NBX_DIR/history/$i")
    if [[ "$s" == "$slot_name" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

# Returns step numbers that directly depend on the given slot name (one per line).
nbx_dependents() {
  local slot_name="${1#\$}"
  local depth
  depth=$(nbx_history_depth)
  local i
  for ((i = 1; i <= depth; i++)); do
    local entry input query
    entry=$(cat "$NBX_DIR/history/$i")
    input=$(cut -f1 <<< "$entry")
    query=$(cut -f2 <<< "$entry")

    # Check input field
    if [[ "$input" == "$NBX_DIR/slots/${slot_name}.json" ]]; then
      echo "$i"
      continue
    fi

    # Check query for $slot_name reference
    if [[ "$query" =~ \$${slot_name}([^a-zA-Z0-9_]|$) ]]; then
      echo "$i"
    fi
  done
}

# Returns all downstream step numbers transitively (BFS, one per line, sorted).
nbx_transitive_dependents() {
  local slot_name="${1#\$}"
  local queue="$slot_name"
  local visited=""

  while [[ -n "$queue" ]]; do
    local current
    current=$(echo "$queue" | head -1)
    queue=$(echo "$queue" | tail -n +2)
    [[ -z "$current" ]] && continue

    local dep_steps
    dep_steps=$(nbx_dependents "$current")
    local step
    while IFS= read -r step; do
      [[ -z "$step" ]] && continue
      # Check if already visited
      local already=false
      while IFS= read -r v; do
        [[ "$v" == "$step" ]] && { already=true; break; }
      done <<< "$visited"
      if ! $already; then
        visited=$(printf '%s\n%s' "$visited" "$step")
        echo "$step"
        # Add this step's output slot to the queue
        local dep_slot
        dep_slot=$(cut -f3 "$NBX_DIR/history/$step")
        queue=$(printf '%s\n%s' "$queue" "$dep_slot")
      fi
    done <<< "$dep_steps"
  done | sort -n
}

# --- Staleness tracking ---

nbx_is_stale() {
  local n="$1"
  [[ -f "$NBX_DIR/.stale" ]] && grep -qx "$n" "$NBX_DIR/.stale"
}

nbx_mark_stale() {
  local n="$1"
  nbx_is_stale "$n" && return 0
  echo "$n" >> "$NBX_DIR/.stale"
}

nbx_clear_stale() {
  local n="$1"
  [[ -f "$NBX_DIR/.stale" ]] || return 0
  grep -vx "$n" "$NBX_DIR/.stale" > "$NBX_DIR/.stale.tmp" || true
  mv "$NBX_DIR/.stale.tmp" "$NBX_DIR/.stale"
  # Remove empty file
  [[ -s "$NBX_DIR/.stale" ]] || rm -f "$NBX_DIR/.stale"
}

# Returns all stale step numbers, sorted ascending.
nbx_stale_steps() {
  [[ -f "$NBX_DIR/.stale" ]] || return 0
  sort -n "$NBX_DIR/.stale"
}

# Mark all transitive dependents of step N's output slot as stale.
nbx_propagate_staleness() {
  local step_num="$1"
  local slot_name
  slot_name=$(cut -f3 "$NBX_DIR/history/$step_num")
  local deps
  deps=$(nbx_transitive_dependents "$slot_name")
  [[ -z "$deps" ]] && return 0
  local dep
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    nbx_mark_stale "$dep"
  done <<< "$deps"
}

# --- Failed step tracking ---

nbx_is_failed() {
  local n="$1"
  [[ -f "$NBX_DIR/.failed" ]] && grep -qx "$n" "$NBX_DIR/.failed"
}

nbx_mark_failed() {
  local n="$1"
  nbx_is_failed "$n" && return 0
  echo "$n" >> "$NBX_DIR/.failed"
}

nbx_clear_failed() {
  local n="$1"
  [[ -f "$NBX_DIR/.failed" ]] || return 0
  grep -vx "$n" "$NBX_DIR/.failed" > "$NBX_DIR/.failed.tmp" || true
  mv "$NBX_DIR/.failed.tmp" "$NBX_DIR/.failed"
  [[ -s "$NBX_DIR/.failed" ]] || rm -f "$NBX_DIR/.failed"
}

nbx_failed_error() {
  local n="$1"
  local errfile="$NBX_DIR/.failed_err/$n"
  [[ -f "$errfile" ]] && cat "$errfile"
}

nbx_save_failed_error() {
  local n="$1" msg="$2"
  mkdir -p "$NBX_DIR/.failed_err"
  echo "$msg" > "$NBX_DIR/.failed_err/$n"
}

nbx_clear_failed_error() {
  local n="$1"
  rm -f "$NBX_DIR/.failed_err/$n"
}
