#!/usr/bin/env bash
# nbx jq: slot injection, autocomplete suggestions

# --- Slot injection (pass all slots as jq variables) ---

# Build --slurpfile args and unwrap prefix for all slots.
# Sets: NBX_JQ_ARGS (array), NBX_JQ_UNWRAP (string)
# Usage: nbx_build_slot_args; jq "${NBX_JQ_ARGS[@]}" "${NBX_JQ_UNWRAP}${query}" "$file"
nbx_build_slot_args() {
  NBX_JQ_ARGS=()
  NBX_JQ_UNWRAP=""
  local f
  for f in "$NBX_DIR/slots"/*.json; do
    [[ -f "$f" ]] || continue
    local name
    name=$(basename "$f" .json)
    name="${name#\$}"
    NBX_JQ_ARGS+=(--slurpfile "$name" "$f")
    NBX_JQ_UNWRAP+="(\$${name}[0]) as \$${name} | "
  done
}

# Run jq with all slots injected as variables.
# Usage: nbx_jq_with_slots "$query" "$input_file"
nbx_jq_with_slots() {
  local query="$1" input_file="$2"
  nbx_build_slot_args
  jq "${NBX_JQ_ARGS[@]}" "${NBX_JQ_UNWRAP}${query}" "$input_file"
}

# Run jq with error capture, save result to slot.
# Returns 0 on success (including empty results), 1 on jq error.
# On error: partial results are still saved, errors go to stderr.
# Usage: nbx_exec_jq "$query" "$input_file" "$slot_name"
nbx_exec_jq() {
  local query="$1" input_file="$2" slot_name="$3"
  local exec_err exec_out
  exec_err=$(mktemp)
  exec_out=$(nbx_jq_with_slots "$query" "$input_file" 2>"$exec_err")

  if [[ -s "$exec_err" ]]; then
    [[ -n "$exec_out" ]] && echo "$exec_out" | nbx_save_slot "$slot_name"
    head -3 "$exec_err" >&2
    rm -f "$exec_err"
    return 1
  fi
  rm -f "$exec_err"

  echo "$exec_out" | nbx_save_slot "$slot_name"
}


# --- Autocomplete ---

nbx_build_suggestions() {
  local input_file="$1"
  # Read only first 50KB for structure detection
  head -c 51200 "$input_file" | jq -r '
    def paths_str:
      . as $v |
      if type == "object" then
        keys[] as $k |
        ".\($k)",
        ($v[$k] | if type == "object" then
          keys[] as $k2 | ".\($k).\($k2)"
        elif type == "array" then
          ".\($k)[]", ".\($k)[0]", ".\($k) | length"
        else empty end)
      elif type == "array" then
        ".[]", ".[0]", ".[-1]", ".[0:5]", ". | length",
        (.[0]? // empty | if type == "object" then
          keys[] as $k |
          ".[] | .\($k)",
          "[.[] | .\($k)]",
          "map(.\($k))",
          "select(.\($k))",
          "{(\($k)): .\($k)}"
        else empty end)
      else empty end;
    paths_str
  ' "$input_file" 2>/dev/null | sort -u
  printf '%s\n' "keys" "values" "length" "type" \
    "to_entries" "from_entries" "flatten" "unique" \
    "sort_by(.)" "group_by(.)" "select(.)" "map(.)" \
    '{name: .}' '[.[] | .]'
}
