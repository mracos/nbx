#!/usr/bin/env bash
# nbx bulk: replay steps from edited text

# Replay steps from a bulk edit file.
# Format: "source │ filter → $slot" per line, # comments ignored.
# Usage: nbx_bulk_replay "file"
nbx_bulk_replay() {
  local file="$1"
  [[ -f "$file" ]] || { warn "No file: $file"; return 1; }

  local bulk_lines=()
  local bulk_line
  while IFS= read -r bulk_line; do
    [[ "$bulk_line" == \#* ]] && continue
    [[ -z "$bulk_line" ]] && continue
    bulk_lines+=("$bulk_line")
  done < "$file"

  [[ ${#bulk_lines[@]} -eq 0 ]] && { warn "No steps"; return 1; }

  # Backup state for rollback
  local backup_dir="$NBX_DIR/.bulk_backup"
  rm -rf "$backup_dir"
  mkdir -p "$backup_dir"
  cp -R "$NBX_DIR/slots" "$backup_dir/slots"
  cp -R "$NBX_DIR/history" "$backup_dir/history"
  [[ -f "$NBX_DIR/.hidden" ]] && cp "$NBX_DIR/.hidden" "$backup_dir/.hidden"

  # Reset and replay from scratch
  nbx_reset

  local bulk_ok=0 bulk_fail=0
  for bulk_line in "${bulk_lines[@]}"; do
    # Strip leading whitespace, [N] prefix, and trailing (hidden)
    bulk_line=$(echo "$bulk_line" | sed 's/^[[:space:]]*//; s/^\[[0-9]*\][[:space:]]*//; s/ (hidden)$//')

    # Parse: source -> filter -> $slot
    # Last " -> $..." is the slot, first part is source, middle is filter
    if [[ "$bulk_line" != *" -> \$"* ]]; then
      warn "Can't parse: $bulk_line"
      bulk_fail=$((bulk_fail + 1))
      continue
    fi
    local bulk_slot="${bulk_line##* -> \$}"
    bulk_line="${bulk_line% -> \$*}"

    # Split remaining "source -> filter" on first " -> "
    if [[ "$bulk_line" != *" -> "* ]]; then
      warn "Can't parse (missing source -> filter): $bulk_line"
      bulk_fail=$((bulk_fail + 1))
      continue
    fi
    local bulk_source="${bulk_line%% -> *}"
    local bulk_filter="${bulk_line#* -> }"

    # Strip metadata suffix (e.g. "  15 array", "  1 string")
    bulk_filter=$(echo "$bulk_filter" | sed -E 's/[[:space:]]{2,}[0-9]+[[:space:]]+[a-z]+$//')

    # Input/set type
    if [[ "$bulk_source" == "input" ]]; then
      if echo "$bulk_filter" | jq '.' &>/dev/null; then
        echo "$bulk_filter" | jq '.' | nbx_save_slot "$bulk_slot"
      else
        jq -n --arg v "$bulk_filter" '$v' | nbx_save_slot "$bulk_slot"
      fi
      nbx_push_history "input" "$bulk_filter" "${bulk_slot#\$}" "input"
      result "$bulk_slot" "set"
      bulk_ok=$((bulk_ok + 1))
      continue
    fi

    # Resolve source: slot reference or file
    local bulk_input=""
    if [[ "$bulk_source" == \$* ]]; then
      bulk_input="$NBX_DIR/slots/${bulk_source#\$}.json"
    else
      bulk_input=$(nbx_resolve_file "$bulk_source") || bulk_input=""
    fi

    if [[ -z "$bulk_input" || ! -f "$bulk_input" ]]; then
      warn "Source not found: $bulk_source"
      bulk_fail=$((bulk_fail + 1))
      continue
    fi

    # Execute filter
    local bulk_err
    bulk_err=$(nbx_exec_jq "$bulk_filter" "$bulk_input" "${bulk_slot#\$}" 2>&1)
    local bulk_rc=$?
    if [[ $bulk_rc -eq 0 ]]; then
      nbx_push_history "$bulk_input" "$bulk_filter" "${bulk_slot#\$}" "query"
      result "$bulk_slot" "$(nbx_slot_rows "${bulk_slot#\$}") rows"
      bulk_ok=$((bulk_ok + 1))
    else
      warn "Filter failed: $bulk_filter"
      [[ -n "$bulk_err" ]] && warn "  $bulk_err"
      bulk_fail=$((bulk_fail + 1))
    fi
  done

  if [[ "$bulk_fail" -gt 0 ]]; then
    # Rollback: restore pre-replay state
    rm -rf "$NBX_DIR/slots" "$NBX_DIR/history" "$NBX_DIR/.hidden"
    cp -R "$backup_dir/slots" "$NBX_DIR/slots"
    cp -R "$backup_dir/history" "$NBX_DIR/history"
    [[ -f "$backup_dir/.hidden" ]] && cp "$backup_dir/.hidden" "$NBX_DIR/.hidden"
    warn "Rolled back — notebook unchanged"
  fi
  rm -rf "$backup_dir"

  plain "Bulk: $bulk_ok ok, $bulk_fail failed"
  [[ "$bulk_fail" -eq 0 ]]
}
