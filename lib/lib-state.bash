#!/usr/bin/env bash
# nbx state management: slots, history, hidden steps

# Step-number list files maintained alongside history (renumbered on delete/move)
NBX_STEP_LISTS=(".hidden" ".stale" ".failed")

# --- State ---

nbx_init_state() {
  mkdir -p "$NBX_DIR/slots" "$NBX_DIR/history" "$NBX_DIR/backups"
}

# --- Edit backups ---

# Save slot data + history entry before an edit overwrites them.
nbx_backup_step() {
  local step_num="$1"
  local slot
  slot=$(nbx_history_field "$step_num" slot)
  local backup_dir="$NBX_DIR/backups/$step_num"
  mkdir -p "$backup_dir"
  cp "$NBX_DIR/slots/${slot}.json" "$backup_dir/slot.json"
  cp "$NBX_DIR/history/$step_num" "$backup_dir/history"
}

# Restore a step from its backup. Returns 1 if no backup exists.
nbx_restore_step() {
  local step_num="$1"
  local backup_dir="$NBX_DIR/backups/$step_num"
  [[ -d "$backup_dir" ]] || return 1
  local slot
  slot=$(cut -f3 "$backup_dir/history")
  cp "$backup_dir/slot.json" "$NBX_DIR/slots/${slot}.json"
  cp "$backup_dir/history" "$NBX_DIR/history/$step_num"
  rm -rf "$backup_dir"
}

nbx_has_backup() {
  local step_num="$1"
  [[ -d "$NBX_DIR/backups/$step_num" ]]
}

nbx_save_slot() {
  local name="${1#\$}"
  local f="$NBX_DIR/slots/${name}.json"
  # Normalize: if input is a stream (multiple values), wrap in array
  local raw
  raw=$(cat)
  local count
  count=$(echo "$raw" | jq -s 'length' 2>/dev/null)
  if [[ "$count" -gt 1 ]]; then
    echo "$raw" | jq -s '.' > "$f"
  else
    echo "$raw" > "$f"
  fi
}

nbx_list_slots() {
  local f
  for f in "$NBX_DIR/slots"/*.json; do
    [[ -f "$f" ]] || continue
    basename "$f" .json
  done
}

nbx_slot_rows() {
  local f="$NBX_DIR/slots/${1#\$}.json"
  [[ -f "$f" ]] || { echo "0"; return; }
  # Use -s to slurp multiple values into array, then count
  local count
  count=$(jq -s 'if length == 1 then .[0] | if type == "array" then length else 1 end else length end' "$f" 2>/dev/null | head -1)
  echo "${count:-1}"
}

nbx_slot_type() {
  local f="$NBX_DIR/slots/${1#\$}.json"
  [[ -f "$f" ]] || { echo "unknown"; return; }
  local t
  t=$(jq -s 'if length == 1 then .[0] | type else "stream" end' "$f" 2>/dev/null | head -1 | tr -d '"')
  echo "${t:-unknown}"
}

# --- History ---
# Entry format: input\tquery\tslot\ttype

nbx_history_field() {
  local pos
  case "$2" in
    input) pos=1 ;; query) pos=2 ;; slot) pos=3 ;; type) pos=4 ;;
  esac
  cut -f"$pos" "$NBX_DIR/history/$1"
}

nbx_push_history() {
  local input="$1" query="$2" slot="$3" type="${4:-query}"
  local depth
  depth=$(nbx_history_depth)
  nbx_set_history "$((depth + 1))" "$input" "$query" "$slot" "$type"
}

nbx_set_history() {
  local step="$1" input="$2" query="$3" slot="$4" type="${5:-query}"
  printf '%s\t%s\t%s\t%s\n' "$input" "$query" "$slot" "$type" > "$NBX_DIR/history/$step"
}

nbx_pop_history() {
  local depth
  depth=$(nbx_history_depth)
  [[ "$depth" -eq 0 ]] && return 1
  local slot
  slot=$(nbx_history_field "$depth" slot)
  rm -f "$NBX_DIR/history/$depth" "$NBX_DIR/slots/${slot}.json"
}

nbx_get_history() {
  local f="$NBX_DIR/history/$1"
  [[ -f "$f" ]] || return 1
  cat "$f"
}

nbx_delete_history() {
  local n="$1"
  local depth
  depth=$(nbx_history_depth)
  [[ "$n" -lt 1 || "$n" -gt "$depth" ]] && return 1

  # Remove slot and history entry
  local slot
  slot=$(nbx_history_field "$n" slot)
  rm -f "$NBX_DIR/slots/${slot#\$}.json" "$NBX_DIR/history/$n"

  # Clear pin if the deleted slot was pinned
  local pinned
  pinned=$(nbx_pinned_slot) && [[ "$pinned" == "${slot#\$}" ]] && nbx_unpin

  # Remove from step-number lists (hidden, stale, etc.)
  local listfile listname
  for listname in "${NBX_STEP_LISTS[@]}"; do
    listfile="$NBX_DIR/$listname"
    [[ -f "$listfile" ]] || continue
    local new_entries=()
    while IFS= read -r h; do
      if [[ "$h" -lt "$n" ]]; then
        new_entries+=("$h")
      elif [[ "$h" -gt "$n" ]]; then
        new_entries+=("$((h - 1))")
      fi
    done < "$listfile"
    if [[ ${#new_entries[@]} -gt 0 ]]; then
      printf '%s\n' "${new_entries[@]}" > "$listfile"
    else
      rm -f "$listfile"
    fi
  done

  # Renumber: shift entries above n down by 1
  local i
  for ((i = n + 1; i <= depth; i++)); do
    mv "$NBX_DIR/history/$i" "$NBX_DIR/history/$((i - 1))"
  done
}

nbx_move_history() {
  local from="$1" to="$2"
  local depth
  depth=$(nbx_history_depth)
  [[ "$from" -lt 1 || "$from" -gt "$depth" ]] && return 1
  [[ "$to" -lt 1 || "$to" -gt "$depth" ]] && return 1
  [[ "$from" -eq "$to" ]] && return 0

  # Stash the moving entry
  local tmp="$NBX_DIR/history/.moving"
  mv "$NBX_DIR/history/$from" "$tmp"

  # Track which step-number lists the moving entry belongs to
  local was_in_list="" listname listfile
  for listname in "${NBX_STEP_LISTS[@]}"; do
    listfile="$NBX_DIR/$listname"
    [[ -f "$listfile" ]] && grep -qx "$from" "$listfile" && was_in_list="$was_in_list $listname"
  done

  # Shift entries to fill the gap
  local i
  if [[ "$from" -lt "$to" ]]; then
    for ((i = from; i < to; i++)); do
      mv "$NBX_DIR/history/$((i + 1))" "$NBX_DIR/history/$i"
    done
  else
    for ((i = from; i > to; i--)); do
      mv "$NBX_DIR/history/$((i - 1))" "$NBX_DIR/history/$i"
    done
  fi
  mv "$tmp" "$NBX_DIR/history/$to"

  # Rebuild step-number lists with new positions
  for listname in "${NBX_STEP_LISTS[@]}"; do
    listfile="$NBX_DIR/$listname"
    [[ -f "$listfile" ]] || continue
    local was_in=false
    [[ "$was_in_list" == *"$listname"* ]] && was_in=true
    local new_entries=()
    while IFS= read -r h; do
      [[ "$h" -eq "$from" ]] && continue
      local nh="$h"
      if [[ "$from" -lt "$to" ]]; then
        [[ "$h" -gt "$from" && "$h" -le "$to" ]] && nh=$((h - 1))
      else
        [[ "$h" -ge "$to" && "$h" -lt "$from" ]] && nh=$((h + 1))
      fi
      new_entries+=("$nh")
    done < "$listfile"
    $was_in && new_entries+=("$to")
    if [[ ${#new_entries[@]} -gt 0 ]]; then
      printf '%s\n' "${new_entries[@]}" > "$listfile"
    else
      rm -f "$listfile"
    fi
  done
}

nbx_history_depth() {
  local count=0
  for f in "$NBX_DIR/history"/*; do
    [[ -f "$f" ]] && count=$((count + 1))
  done
  echo "$count"
}

nbx_reset() {
  rm -rf "$NBX_DIR/slots" "$NBX_DIR/history" "$NBX_DIR/backups" "$NBX_DIR/.failed_err"
  local listname
  for listname in "${NBX_STEP_LISTS[@]}"; do
    rm -f "$NBX_DIR/$listname"
  done
  nbx_unpin
  nbx_stash_clear
  nbx_init_state
}

# --- Hidden steps ---

nbx_is_hidden() {
  local n="$1"
  [[ -f "$NBX_DIR/.hidden" ]] && grep -qx "$n" "$NBX_DIR/.hidden"
}

nbx_toggle_hidden() {
  local n="$1"
  local hidden_file="$NBX_DIR/.hidden"
  if nbx_is_hidden "$n"; then
    grep -vx "$n" "$hidden_file" > "$hidden_file.tmp" && mv "$hidden_file.tmp" "$hidden_file"
    echo "unhidden"
  else
    echo "$n" >> "$hidden_file"
    echo "hidden"
  fi
}

# --- Pinned slot ---

nbx_pin() {
  local slot_name="${1#\$}"
  echo "$slot_name" > "$NBX_DIR/.pinned"
}

nbx_unpin() {
  rm -f "$NBX_DIR/.pinned"
}

nbx_pinned_slot() {
  [[ -f "$NBX_DIR/.pinned" ]] && cat "$NBX_DIR/.pinned"
}

nbx_is_pinned() {
  [[ -f "$NBX_DIR/.pinned" ]]
}

# --- Query stash (scratchpad) ---
# The stash file is written and read inline by the fzf query-view
# (lib-fzf.bash); nbx_stash_clear resets it on `nbx reset`.

nbx_stash_clear() {
  rm -f "$NBX_DIR/.stash" "$NBX_DIR/.stash_idx"
}

# --- Command sources (ADR 0010) ---
# Maps a source-file basename to the command that produced it, so `-c` sources
# can be re-run on reload. File-backed (bash 3.2 has no associative arrays),
# same pattern as the stash. Entry format: basename\tcommand
#
# Usage: nbx_source_cmd_add <basename> <command>
nbx_source_cmd_add() {
  # Flatten tabs and newlines: the .commands file is one label<TAB>command per
  # line, so either would corrupt the record. Spaces and quotes are fine.
  local label="$1" cmd="${2//$'\t'/ }"
  cmd="${cmd//$'\n'/ }"
  local f="$NBX_DIR/.commands"
  # Dedup by label: drop any existing entry, then append.
  if [[ -f "$f" ]]; then
    grep -v "^${label}"$'\t' "$f" > "$f.tmp" 2>/dev/null || true
    mv "$f.tmp" "$f"
  fi
  printf '%s\t%s\n' "$label" "$cmd" >> "$f"
}

nbx_source_cmd_list() {
  [[ -f "$NBX_DIR/.commands" ]] && cat "$NBX_DIR/.commands"
}

# Command for a given source basename, empty if not a command source.
nbx_source_cmd_get() {
  local label="$1"
  [[ -f "$NBX_DIR/.commands" ]] || return 0
  awk -F'\t' -v l="$label" '$1 == l { print $2; exit }' "$NBX_DIR/.commands"
}

# Label of the source whose command matches (for dedup), empty if none. Compares
# against the flattened form the command is stored in (see nbx_source_cmd_add).
nbx_source_cmd_find_label() {
  local cmd="${1//$'\t'/ }"
  cmd="${cmd//$'\n'/ }"
  [[ -f "$NBX_DIR/.commands" ]] || return 0
  awk -F'\t' -v c="$cmd" '$2 == c { print $1; exit }' "$NBX_DIR/.commands"
}

# True if a source basename came from a stored command.
nbx_is_command_source() {
  local label="$1"
  [[ -f "$NBX_DIR/.commands" ]] && grep -q "^${label}"$'\t' "$NBX_DIR/.commands"
}

# --- Tabular source inputs (ADR 0009) ---
# Maps a source label to the file it was converted from, so a query can notice
# the file changed on disk. Session-only on purpose: it is not written to the
# notebook, so opening one never re-runs a conversion by itself (ADR 0010).
# Entry format: label\tpath

nbx_source_file_add() {
  local label="$1" path="${2//$'\t'/ }"
  path="${path//$'\n'/ }"
  local f="$NBX_DIR/.srcfiles"
  if [[ -f "$f" ]]; then
    grep -v "^${label}"$'\t' "$f" > "$f.tmp" 2>/dev/null || true
    mv "$f.tmp" "$f"
  fi
  printf '%s\t%s\n' "$label" "$path" >> "$f"
}

nbx_source_file_get() {
  local label="$1"
  [[ -f "$NBX_DIR/.srcfiles" ]] || return 0
  awk -F'\t' -v l="$label" '$1 == l { print $2; exit }' "$NBX_DIR/.srcfiles"
}
