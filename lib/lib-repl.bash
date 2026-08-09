#!/usr/bin/env bash
# nbx REPL infrastructure: input resolution, slot naming, banner, dispatch

# --- Save helpers ---

nbx_save_draft() {
  [[ -n "$NBX_NOTEBOOK" ]] || return 0
  local depth
  depth=$(nbx_history_depth)
  [[ "$depth" -eq 0 ]] && return 0
  nbx_ipynb_save "$NBX_DIR/.draft.ipynb"
}

nbx_mark_dirty() {
  NBX_DIRTY=true
  nbx_save_draft
}

nbx_on_exit() {
  if [[ "$NBX_DIRTY" == true && -n "$NBX_NOTEBOOK" ]]; then
    printf '\n  Unsaved changes. Save to %s? [Y/n] ' "$(basename "$NBX_NOTEBOOK")" >&2
    local answer
    read -r answer <&0 2>/dev/null || answer="y"
    if [[ "${answer:-y}" != [nN]* ]]; then
      nbx_ipynb_save "$NBX_NOTEBOOK"
      info "Saved." >&2
    else
      info "Draft at: $NBX_DIR/.draft.ipynb" >&2
    fi
  fi
}

# --- Staleness prompt ---

nbx_prompt_replay_stale() {
  local stale_count
  stale_count=$(nbx_stale_steps | grep -c . || true)
  [[ "$stale_count" -eq 0 ]] && return 0

  # Auto-replay when a slot is pinned — the user opted into reactivity
  if nbx_is_pinned; then
    nbx_cmd_replay "--stale"
    return 0
  fi

  printf '  %s ' "$stale_count downstream step(s) stale — replay? [Y/n]" >&2
  local answer
  read -r answer <&0 2>/dev/null || answer="y"
  if [[ "${answer:-y}" != [nN]* ]]; then
    # Best-effort: a downstream step that now errors is reported by replay and
    # left marked failed; it must not abort the edit/undo that triggered this.
    nbx_cmd_replay "--stale" || true
  else
    info "Run 'replay' when ready"
  fi
  return 0
}

# --- Command sources (ADR 0010) ---

# Next free cmdN label, so launch args and in-REPL commands never collide.
# Labels are extensionless (cmd1, cmd2, …) so they read as typeable source names.
nbx_next_command_label() {
  local i=1
  while [[ -e "$NBX_DIR/sources/cmd${i}" ]]; do
    i=$((i + 1))
  done
  echo "cmd${i}"
}

# jq only speaks JSON, so if a command emits plain text, wrap its lines into a
# JSON string array in place — the source stays queryable (`.[] | select(...)`)
# instead of failing every filter (ADR 0010). NDJSON and real JSON pass untouched.
nbx_wrap_if_not_json() {
  local f="$1" label="$2"
  jq empty "$f" 2>/dev/null && return 0
  local wrapped="$f.nbxwrap"
  if jq -Rn '[inputs]' "$f" > "$wrapped" 2>/dev/null && [[ -s "$wrapped" ]]; then
    mv "$wrapped" "$f"
    info "$label: wrapped non-JSON output into a string array (one line per element)"
  else
    rm -f "$wrapped"
    warn "$label: output is not valid JSON"
  fi
}

# Capture one command's stdout as the next cmdN source: register it in NBX_FILES
# and record the command in .commands for re-runnable persistence. On success sets
# NBX_LAST_SOURCE_LABEL (a global, since command substitution would lose the
# NBX_FILES mutation in a subshell) and returns 0.
nbx_capture_one_command() {
  local cmd="$1"
  mkdir -p "$NBX_DIR/sources"

  # Dedup: an identical command reuses its existing source (refresh to re-run),
  # instead of piling up cmd2, cmd3, … snapshots of the same thing.
  local existing
  existing=$(nbx_source_cmd_find_label "$cmd")
  if [[ -n "$existing" && -e "$NBX_DIR/sources/$existing" ]]; then
    info "$existing: reusing existing source (same command; refresh to re-run)"
    NBX_LAST_SOURCE_LABEL="$existing"
    return 0
  fi

  local label out
  label=$(nbx_next_command_label)
  out="$NBX_DIR/sources/$label"
  if eval "$cmd" > "$out" 2>/dev/null && [[ -s "$out" ]]; then
    nbx_wrap_if_not_json "$out" "$label"
    NBX_FILES+=("$out")
    nbx_source_cmd_add "$label" "$cmd"
    NBX_LAST_SOURCE_LABEL="$label"
    return 0
  fi
  warn "Command produced no output, skipping: $cmd"
  rm -f "$out"
  return 1
}

# Capture several commands (launch `-c` path).
# Usage: nbx_capture_command_sources "<cmd>" ["<cmd>" ...]
nbx_capture_command_sources() {
  local cmd
  for cmd in "$@"; do
    nbx_capture_one_command "$cmd" || true
  done
  return 0
}

# --- File resolution ---

nbx_resolve_file() {
  local name="$1"
  local f
  for f in "${NBX_FILES[@]}"; do
    [[ "$(basename "$f")" == "$name" || "$f" == "$name" ]] && { echo "$f"; return 0; }
  done
  if [[ -f "$name" ]]; then
    echo "$(cd "$(dirname "$name")" && pwd)/$(basename "$name")"
    return 0
  fi
  return 1
}

# --- Input resolution ---

nbx_pick_input() {
  local items=()

  # Loaded files first
  local f
  for f in "${NBX_FILES[@]}"; do
    items+=("$(basename "$f")")
  done

  # Slots
  local slots
  slots=$(nbx_list_slots)
  if [[ -n "$slots" ]]; then
    while IFS= read -r s; do
      items+=("\$$s")
    done <<< "$slots"
  fi

  # Other JSON files in current directory (not already loaded)
  local dir_file
  for dir_file in *.json; do
    [[ -f "$dir_file" ]] || continue
    local already=false
    for f in "${NBX_FILES[@]}"; do
      [[ "$(basename "$f")" == "$dir_file" ]] && { already=true; break; }
    done
    $already || items+=("$dir_file")
  done

  if [[ ${#items[@]} -eq 0 ]]; then
    warn "No JSON/CSV files found in $(pwd)"
    return 1
  fi

  local picked
  picked=$(printf '%s\n' "${items[@]}" | fzf --header "Pick source │ \$name = slot │ files from $(pwd)") || return 1
  [[ -z "$picked" ]] && return 1

  if [[ "$picked" == \$* ]]; then
    echo "$NBX_DIR/slots/${picked#\$}.json"
  else
    local resolved
    if resolved=$(nbx_resolve_file "$picked"); then
      # Add to loaded files if not already there
      local already=false
      for f in "${NBX_FILES[@]}"; do
        [[ "$f" == "$resolved" ]] && { already=true; break; }
      done
      $already || NBX_FILES+=("$resolved")
      echo "$resolved"
    fi
  fi
}

nbx_resolve_input() {
  local ref="$1"
  if [[ "$ref" == \$* ]]; then
    echo "$NBX_DIR/slots/${ref#\$}.json"
  elif [[ "$ref" =~ ^[0-9]+$ ]] && [[ -f "$NBX_DIR/history/$ref" ]]; then
    local slot_name
    slot_name=$(nbx_history_field "$ref" slot)
    echo "$NBX_DIR/slots/${slot_name}.json"
  else
    nbx_resolve_file "$ref" || echo "$ref"
  fi
}

# --- Slot naming ---

nbx_next_slot() {
  echo "s$(($(nbx_history_depth) + 1))"
}

# Slots are exposed as jq variables ($name), which must match
# [a-zA-Z_][a-zA-Z0-9_]*. Fold anything else (spaces, punctuation) to '_' so the
# slot stays referenceable instead of producing an unusable "$my slot". Returns
# empty when nothing usable remains, so the caller can fall back to the default.
nbx_sanitize_slot_name() {
  local name="$1"
  name="${name//[^a-zA-Z0-9_]/_}"                            # invalid chars -> _
  while [[ "$name" == *__* ]]; do name="${name//__/_}"; done # collapse runs
  name="${name#_}"; name="${name%_}"                         # trim edge separators
  [[ "$name" =~ ^[0-9] ]] && name="_$name"                   # can't start with a digit
  printf '%s' "$name"
}

# Sanitize a user-supplied slot name for jq, announcing any change on stderr.
# Prints the jq-safe name; returns 1 (with a warning) when nothing usable remains.
# For the arg-based commands (set/rename/dup); the interactive prompt has its own
# default fallback below.
nbx_coerce_slot_name() {
  local raw="$1" safe
  safe=$(nbx_sanitize_slot_name "$raw")
  [[ -z "$safe" ]] && { warn "Invalid slot name: $raw"; return 1; }
  [[ "$safe" != "$raw" ]] && printf '  %s\n' "$(dim "→ named \$$safe (jq-safe)")" >&2
  printf '%s' "$safe"
}

nbx_prompt_slot_name() {
  local default
  default=$(nbx_next_slot)
  printf '  %s ' "$(dim "Slot name [$default] (Esc to cancel):")" >&2
  local name
  read -r name || return 1
  # ESC produces a literal escape char
  if [[ "$name" == $'\e'* ]]; then
    echo "" >&2
    return 1
  fi
  name="${name:-$default}"
  name="${name#\$}"
  local raw="$name"
  name=$(nbx_sanitize_slot_name "$name")
  [[ -z "$name" ]] && name="$default"
  [[ "$name" != "$raw" ]] && printf '  %s\n' "$(dim "→ named \$$name (jq-safe)")" >&2
  if [[ -f "$NBX_DIR/slots/${name}.json" ]]; then
    printf '  %s ' "$(warn "\$$name exists — overwrite? [y/N]")" >&2
    local confirm
    read -r confirm || return 1
    [[ "$confirm" == [yY]* ]] || return 1
  fi
  echo "$name"
}

# --- Banner ---

nbx_banner() {
  echo ""
  plain "$(bold "nbx") $(dim "— interactive jq notebook")"
  [[ -n "$NBX_NOTEBOOK" ]] && info "$(basename "$NBX_NOTEBOOK")"
  if [[ ${#NBX_FILES[@]} -gt 0 ]]; then
    printf '  %s' "$(dim "Sources:")"
    for f in "${NBX_FILES[@]}"; do
      local bn cmd
      bn=$(basename "$f")
      cmd=$(nbx_source_cmd_get "$bn")
      if [[ -n "$cmd" ]]; then
        printf ' %s' "$bn$(dim "($cmd)")"
      else
        printf ' %s' "$bn"
      fi
    done
    echo ""
  fi
  info "Type help for commands, ref for jq cheatsheet"
}

# --- Input display ---

# Human-friendly name for a resolved input path, used as the query-view hint so
# it's clear which source a filter runs against. Slots read as $name, command
# sources show their label (cmdN), everything else is the file's basename.
nbx_input_label() {
  local input_file="$1"
  case "$input_file" in
    "$NBX_DIR/slots/"*) printf '$%s' "$(basename "$input_file" .json)" ;;
    *)                  printf '%s' "${input_file##*/}" ;;
  esac
}

# --- Startup ---

# Decide the launch-time query target. The common first move after `nbx <file>`
# is to query that file, so open the query view straight away instead of dropping
# at the REPL. Prints the source arg for nbx_cmd_query (empty = show the picker;
# a basename when there's a single source, so the picker is skipped) and returns 0
# to auto-open. Returns 1 to stay at the REPL: no sources, or resuming a notebook
# that already has steps (history depth > 0) where the notebook view matters more.
nbx_startup_query_target() {
  [[ "$(nbx_history_depth)" -eq 0 ]] || return 1
  [[ ${#NBX_FILES[@]} -gt 0 ]] || return 1
  [[ ${#NBX_FILES[@]} -eq 1 ]] && printf '%s' "${NBX_FILES[0]##*/}"
  return 0
}

# --- Command dispatch ---

nbx_resolve_cmd() {
  local input="$1"
  local matches=()
  local f
  for f in "$LIB_DIR"/repl/nbx-cmd-*; do
    [[ -f "$f" ]] || continue
    local name
    name=$(basename "$f")
    name="${name#nbx-cmd-}"
    # Exact match wins outright, so a command is never shadowed by a longer one
    # that has it as a prefix (e.g. `ref` vs `refresh`).
    [[ "$name" == "$input" ]] && { echo "$name"; return 0; }
    if [[ "$name" == "$input"* ]]; then
      matches+=("$name")
    fi
  done
  if [[ ${#matches[@]} -eq 1 ]]; then
    echo "${matches[0]}"
  elif [[ ${#matches[@]} -gt 1 ]]; then
    warn "Ambiguous: ${matches[*]}"
    return 1
  else
    return 1
  fi
}
