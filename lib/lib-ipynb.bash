#!/usr/bin/env bash
# nbx ipynb: notebook persistence (save, load, new)

# --- .ipynb persistence ---

# Create a new empty .ipynb notebook
nbx_ipynb_new() {
  local notebook="$1"
  shift
  local files=("$@")

  # Build sources metadata
  local sources_json="[]"
  if [[ ${#files[@]} -gt 0 ]]; then
    sources_json=$(printf '%s\n' "${files[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')
  fi

  jq -n \
    --argjson sources "$sources_json" \
    '{
      nbformat: 4,
      nbformat_minor: 5,
      metadata: {
        nbx: {
          version: "0.1",
          sources: $sources,
          created: (now | strftime("%Y-%m-%dT%H:%M:%S"))
        },
        kernelspec: {
          name: "bash",
          display_name: "Bash (nbx)"
        }
      },
      cells: []
    }' > "$notebook"
}

# Save current session state to .ipynb
nbx_ipynb_save() {
  local notebook="$1"
  [[ -z "$notebook" ]] && return 1

  local depth
  depth=$(nbx_history_depth)

  # Build each cell as a separate JSON file to avoid argv limits
  local cells_dir="$NBX_DIR/.save_cells"
  rm -rf "$cells_dir"
  mkdir -p "$cells_dir"

  local i
  for ((i = 1; i <= depth; i++)); do
    local input query slot type label
    input=$(nbx_history_field "$i" input)
    query=$(nbx_history_field "$i" query)
    slot=$(nbx_history_field "$i" slot)
    type=$(nbx_history_field "$i" type)
    label=$(nbx_input_label "$input")

    local source_cmd="jq '$query' $label"

    local slot_file="$NBX_DIR/slots/${slot#\$}.json"

    local is_hidden="false"
    nbx_is_hidden "$i" && is_hidden="true"

    local is_stale="false"
    nbx_is_stale "$i" && is_stale="true"

    # Read output from file to avoid argv limits
    local output_args=()
    if [[ -f "$slot_file" ]]; then
      output_args=(--rawfile output "$slot_file")
    else
      output_args=(--arg output "")
    fi

    jq -n \
      --arg source "$source_cmd" \
      "${output_args[@]}" \
      --arg slot "$slot" \
      --arg type "$type" \
      --arg input "$input" \
      --arg query "$query" \
      --arg cell_id "cell-$i" \
      --argjson hidden "$is_hidden" \
      --argjson stale "$is_stale" \
      '{
        cell_type: "code",
        id: $cell_id,
        source: [$source],
        metadata: {
          nbx: {
            slot: $slot,
            type: $type,
            input: $input,
            filter: $query
          },
          jupyter: {
            source_hidden: $hidden,
            outputs_hidden: $hidden
          }
        },
        outputs: [{
          output_type: "stream",
          name: "stdout",
          text: [$output]
        }],
        execution_count: (if $stale then null else ($cell_id | ltrimstr("cell-") | tonumber) end)
      }' > "$cells_dir/$(printf '%04d' "$i").json"
  done

  # Build sources list from NBX_FILES, excluding captured command sources
  # (their temppaths are meaningless after the session; see ADR 0010).
  local sources_json="[]"
  if [[ -n "${NBX_FILES[*]:-}" ]]; then
    sources_json=$(printf '%s\n' "${NBX_FILES[@]}" | jq -R -s \
      --arg cap "$NBX_DIR/sources/" \
      'split("\n") | map(select(length > 0 and (startswith($cap) | not)))')
  fi

  # Snapshot EVERY source (files and captured commands) into the notebook so it
  # is fully self-contained — reload works with none of the original files
  # present (ADR 0010, option 3). Command sources also carry their command so
  # they can be refreshed; file sources carry command: null. On reload a live
  # file at its original path wins (metadata.nbx.sources); the snapshot is the
  # offline fallback.
  local command_sources_json="[]"
  if [[ -n "${NBX_FILES[*]:-}" ]]; then
    local entries="$NBX_DIR/.cmdsrc_entries"
    : > "$entries"
    local f bn cmd
    for f in "${NBX_FILES[@]}"; do
      [[ -f "$f" ]] || continue
      bn=$(basename "$f")
      cmd=$(nbx_source_cmd_get "$bn")
      jq -n --arg label "$bn" --arg command "$cmd" --rawfile snapshot "$f" \
        '{label: $label, command: (if $command == "" then null else $command end), snapshot: $snapshot}' \
        >> "$entries"
    done
    [[ -s "$entries" ]] && command_sources_json=$(jq -s '.' "$entries")
    rm -f "$entries"
  fi

  # Assemble notebook: slurp all cell files, no argv limits
  local tmp_notebook="$NBX_DIR/.save_tmp.ipynb"
  jq -s \
    --argjson sources "$sources_json" \
    --argjson command_sources "$command_sources_json" \
    '{
      nbformat: 4,
      nbformat_minor: 5,
      metadata: {
        nbx: {
          version: "0.1",
          sources: $sources,
          command_sources: $command_sources,
          saved: (now | strftime("%Y-%m-%dT%H:%M:%S"))
        },
        kernelspec: {
          name: "bash",
          display_name: "Bash (nbx)"
        }
      },
      cells: .
    }' "$cells_dir"/*.json > "$tmp_notebook"

  # Atomic write: only replace notebook if save succeeded
  if [[ -s "$tmp_notebook" ]] && jq '.' "$tmp_notebook" &>/dev/null; then
    mv "$tmp_notebook" "$notebook"
  else
    warn "Save failed — notebook not modified"
    rm -f "$tmp_notebook"
    return 1
  fi

  rm -rf "$cells_dir"
}

# Restore captured command sources from a notebook (ADR 0010, option 3).
# Writes each saved snapshot back to a source file, with no shell run on open. A
# `-c` source's command is re-recorded so `refresh` can re-run it in-session.
nbx_ipynb_restore_command_sources() {
  local notebook="$1"
  local count
  count=$(jq '.metadata.nbx.command_sources // [] | length' "$notebook" 2>/dev/null)
  [[ "${count:-0}" -gt 0 ]] || return 0

  mkdir -p "$NBX_DIR/sources"
  local i label command
  for ((i = 0; i < count; i++)); do
    label=$(jq -r ".metadata.nbx.command_sources[$i].label // empty" "$notebook")
    [[ -n "$label" ]] || continue
    jq -r ".metadata.nbx.command_sources[$i].snapshot // \"\"" "$notebook" > "$NBX_DIR/sources/$label"
    local already=false f
    for f in ${NBX_FILES[@]+"${NBX_FILES[@]}"}; do
      [[ "$f" == "$NBX_DIR/sources/$label" ]] && { already=true; break; }
    done
    $already || NBX_FILES+=("$NBX_DIR/sources/$label")
    command=$(jq -r ".metadata.nbx.command_sources[$i].command // \"\"" "$notebook")
    [[ -n "$command" ]] && nbx_source_cmd_add "$label" "$command"
  done
  return 0
}

# Load a .ipynb and restore cells from cached outputs
nbx_ipynb_load() {
  local notebook="$1"
  [[ -f "$notebook" ]] || { warn "Not found: $notebook"; return 1; }

  nbx_reset
  nbx_ipynb_restore_command_sources "$notebook"

  # Extract all cell metadata in a single jq call (no outputs — those are multi-line)
  local cells_meta
  cells_meta=$(jq -r '
    [.cells | to_entries[] |
     select(.value.metadata.nbx.slot // empty | length > 0) |
     .key] | .[]
  ' "$notebook")

  [[ -z "$cells_meta" ]] && { info "No cells found in $(basename "$notebook")"; return 0; }

  # Extract metadata for all cells (no filter — @tsv escapes backslashes)
  local all_meta
  all_meta=$(jq -r '
    [.cells[] | select(.metadata.nbx.slot // empty | length > 0)] |
    .[] | [
      .metadata.nbx.slot,
      (.metadata.nbx.type // "query"),
      (.metadata.nbx.input // ""),
      (.metadata.jupyter.source_hidden // false | tostring),
      (.execution_count // "null" | tostring)
    ] | @tsv
  ' "$notebook")

  local step=0
  while IFS=$'\t' read -r slot type input_ref is_hidden exec_count; do
    # Extract filter separately with -r to preserve backslashes
    local filter
    filter=$(jq -r "
      [.cells[] | select(.metadata.nbx.slot // empty | length > 0)][$step] |
      .metadata.nbx.filter // \".\"
    " "$notebook")
    slot="${slot#\$}"
    # Resolve input path for history (find actual file if possible)
    local input_file="$input_ref"
    if [[ "$input_ref" == *"/slots/"* ]]; then
      local ref_slot
      ref_slot=$(basename "$input_ref" .json)
      input_file="$NBX_DIR/slots/${ref_slot}.json"
    elif [[ ! -f "$input_ref" ]]; then
      local bn
      bn=$(basename "$input_ref")
      for f in "${NBX_FILES[@]}"; do
        if [[ "$(basename "$f")" == "$bn" ]]; then
          input_file="$f"
          break
        fi
      done
    fi

    # Restore from cached output (handle text as string or array per ipynb spec)
    local cached_output
    cached_output=$(jq -r "
      [.cells[] | select(.metadata.nbx.slot // empty | length > 0)][$step] |
      .outputs[0].text // empty |
      if type == \"array\" then .[0] // empty
      elif type == \"string\" then .
      else empty end
    " "$notebook")

    step=$((step + 1))
    local restored=false

    # Try cache first — valid JSON means instant restore
    if [[ -n "$cached_output" ]] && echo "$cached_output" | jq '.' &>/dev/null; then
      echo "$cached_output" > "$NBX_DIR/slots/${slot}.json"
      restored=true
    fi

    # Cache missing or truncated — re-execute if source file is available
    if ! $restored; then
      local resolved_input="$input_file"
      [[ "$input_ref" == *"/slots/"* ]] && resolved_input="$NBX_DIR/slots/$(basename "$input_ref" .json).json"

      if [[ -f "$resolved_input" ]]; then
        case "$type" in
          pick)
            # Re-execute index-based filter; legacy "picked N" can't replay
            if [[ "$filter" == picked* ]]; then
              warn "Cell $step (\$$slot): legacy pick, can't re-execute"
              continue
            fi
            nbx_jq_with_slots "$filter" "$resolved_input" > "$NBX_DIR/slots/${slot}.json" 2>/dev/null
            ;;
          input)
            if echo "$filter" | jq '.' &>/dev/null; then
              echo "$filter" | jq '.' > "$NBX_DIR/slots/${slot}.json"
            else
              jq -n --arg v "$filter" '$v' > "$NBX_DIR/slots/${slot}.json"
            fi
            ;;
          *)
            nbx_jq_with_slots "$filter" "$resolved_input" > "$NBX_DIR/slots/${slot}.json" 2>/dev/null
            ;;
        esac
        restored=true
      fi
    fi

    if ! $restored; then
      warn "Skipping cell $step: no valid cache and source not found for \$$slot"
      continue
    fi

    nbx_push_history "$input_file" "$filter" "$slot" "$type"

    [[ "$is_hidden" == "true" ]] && echo "$step" >> "$NBX_DIR/.hidden"
    [[ "$exec_count" == "null" ]] && echo "$step" >> "$NBX_DIR/.stale"
  done <<< "$all_meta"

  local loaded
  loaded=$(nbx_history_depth)
  info "Loaded $loaded cells from $(basename "$notebook")"
}
