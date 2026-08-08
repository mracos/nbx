#!/usr/bin/env bash
# nbx fzf: query editor, row picker, cheatsheet

# --- fzf query editor ---

nbx_fzf_query() {
  local input_file="$1"
  local initial_query="${2:-.}"
  local context_label="${3:-}"
  local lib_dir
  lib_dir="${BASH_SOURCE[0]%/*}"
  local cheatsheet="$lib_dir/cheatsheet.txt"

  # Start with cheatsheet patterns immediately, build file suggestions in background
  local suggestions_file="$NBX_DIR/.suggestions"
  awk '/^[^#]/ && NF { sub(/  +.*/, ""); print }' "$cheatsheet" > "$suggestions_file"

  # Add slot names as $var suggestions
  local slot_name
  for slot_name in $(nbx_list_slots); do
    echo "\$${slot_name}" >> "$suggestions_file"
  done

  # Build file-specific suggestions in background
  (nbx_build_suggestions "$input_file" >> "$suggestions_file") &

  local query_file="$NBX_DIR/.query"
  echo "$initial_query" > "$query_file"

  # Stash state files
  local stash_file="$NBX_DIR/.stash"
  local stash_idx_file="$NBX_DIR/.stash_idx"
  echo "0" > "$stash_idx_file"

  # Preview script: shows slots, stash mini-list, then query result
  local preview_script="$NBX_DIR/.preview.sh"
  cat > "$preview_script" <<'PREVIEW_EOF'
#!/usr/bin/env bash
query_file="$1"
input_file="$2"
slots_dir="$3"
full_mode="${4:-}"
lib_dir="$5"
stash_file="${6:-}"
stash_idx_file="${7:-}"
NBX_DIR="${slots_dir%/slots}"
export NBX_DIR

source "$lib_dir/lib-state.bash"
source "$lib_dir/lib-jq.bash"
source "$lib_dir/lib-display.bash"

query=$(cat "$query_file")
err_file="$NBX_DIR/.preview_err"

# Slots
nbx_build_slot_args
has_slots=false
for f in "$slots_dir"/*.json; do
  [ -f "$f" ] || continue
  has_slots=true
  name=$(basename "$f" .json)
  name="${name#\$}"
  preview=$(jq -c '.' "$f" 2>/dev/null | head -c 60)
  info "\$${name} = ${preview}"
done
$has_slots && info "$(separator)"

# Stash mini-list
if [ -n "$stash_file" ] && [ -f "$stash_file" ] && [ -s "$stash_file" ]; then
  current_idx=0
  [ -f "$stash_idx_file" ] && current_idx=$(cat "$stash_idx_file")
  n=1
  shown=0
  while IFS=$'\t' read -r sq sr st; do
    marker=""
    [ "$n" -eq "$current_idx" ] && marker=$'  \033[1m\xe2\x86\x90\033[0m'
    printf '  \033[2m[S%d]\033[0m %s  \033[2m%s %s\033[0m%s\n' "$n" "$sq" "$sr" "$st" "$marker"
    n=$((n + 1))
    shown=$((shown + 1))
    [ "$shown" -ge 5 ] && break
  done < "$stash_file"
  total=$(wc -l < "$stash_file" | tr -d ' ')
  [ "$total" -gt 5 ] && info "($((total - 5)) more)"
  info "$(separator)"
fi

# Query result
limit="head -200"
[ "$full_mode" = "full" ] && limit="cat"
result=$(jq -C "${NBX_JQ_ARGS[@]}" "${NBX_JQ_UNWRAP}${query}" "$input_file" 2>"$err_file" | $limit)
if [ -s "$err_file" ]; then
  warn "$(head -3 "$err_file")"
  [ -n "$result" ] && echo "$result"
elif [ -n "$result" ]; then
  echo "$result"
else
  info "(no results)"
fi
PREVIEW_EOF
  chmod +x "$preview_script"

  # Stash helper script (save + cycle subcommands)
  local stash_script="$NBX_DIR/.stash.sh"
  cat > "$stash_script" <<'STASH_EOF'
#!/usr/bin/env bash
cmd="$1"; shift
case "$cmd" in
  save)
    query_file="$1"; input_file="$2"; slots_dir="$3"; lib_dir="$4"
    stash_file="$5"; stash_idx_file="$6"
    reload_cmd="$7"; suggestions_file="$8"
    NBX_DIR="${slots_dir%/slots}"; export NBX_DIR
    source "$lib_dir/lib-state.bash"
    source "$lib_dir/lib-jq.bash"
    query=$(cat "$query_file")
    [ -z "$query" ] && exit 0
    # Compute rows and type
    nbx_build_slot_args
    rows=$(jq "${NBX_JQ_ARGS[@]}" "${NBX_JQ_UNWRAP}${query}" "$input_file" 2>/dev/null | jq -s 'if length == 1 then .[0] | if type == "array" then length else 1 end else length end' 2>/dev/null || echo "?")
    stype=$(jq "${NBX_JQ_ARGS[@]}" "${NBX_JQ_UNWRAP}${query}" "$input_file" 2>/dev/null | jq -s 'if length == 1 then .[0] | type else "stream" end' 2>/dev/null | tr -d '"' || echo "?")
    # Dedup
    if [ -f "$stash_file" ]; then
      while IFS=$'\t' read -r sq _rest; do
        [ "$sq" = "$query" ] && { echo "refresh-preview"; exit 0; }
      done < "$stash_file"
    fi
    printf '%s\t%s\t%s\n' "$query" "$rows" "$stype" >> "$stash_file"
    # Reset idx to 0 (user is on their own query)
    echo "0" > "$stash_idx_file"
    echo "reload($reload_cmd {q} $suggestions_file $stash_file)+refresh-preview"
    ;;
  cycle)
    direction="$1"; stash_file="$2"; stash_idx_file="$3"; query_file="$4"
    [ ! -f "$stash_file" ] && exit 0
    total=$(wc -l < "$stash_file" | tr -d ' ')
    [ "$total" -eq 0 ] && exit 0
    idx=0
    [ -f "$stash_idx_file" ] && idx=$(cat "$stash_idx_file")
    # Save original query on first cycle away from 0
    if [ "$idx" -eq 0 ] && [ ! -f "${query_file}.orig" ]; then
      cp "$query_file" "${query_file}.orig"
    fi
    # Adjust index with wrap: 0..total
    idx=$((idx + direction))
    if [ "$idx" -gt "$total" ]; then idx=0; fi
    if [ "$idx" -lt 0 ]; then idx=$total; fi
    echo "$idx" > "$stash_idx_file"
    if [ "$idx" -eq 0 ]; then
      # Return to original query
      q=$(cat "${query_file}.orig")
      rm -f "${query_file}.orig"
    else
      q=$(sed -n "${idx}p" "$stash_file" | cut -f1)
    fi
    # Escape single quotes for fzf action string
    escaped=$(echo "$q" | sed "s/'/'\\\\''/g")
    printf '%s' "$q" > "$query_file"
    echo "change-query($escaped)+refresh-preview"
    ;;
esac
STASH_EOF
  chmod +x "$stash_script"

  # Reload script: prepends stash entries then query-prefixed suggestions
  local reload_script="$NBX_DIR/.reload.sh"
  cat > "$reload_script" <<'RELOAD_EOF'
#!/usr/bin/env bash
q="$1"
suggestions_file="$2"
stash_file="${3:-}"

# Prepend stash entries
if [ -n "$stash_file" ] && [ -f "$stash_file" ] && [ -s "$stash_file" ]; then
  n=1
  while IFS=$'\t' read -r sq sr st; do
    printf '[S%d] %s  %s %s\n' "$n" "$sq" "$sr" "$st"
    n=$((n + 1))
  done < "$stash_file"
  echo "───"
fi

# Extract prefix: everything up to and including the last | or (
prefix=$(echo "$q" | sed -n 's/\(.*[|(] *\).*/\1/p')
if [ -n "$prefix" ]; then
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    echo "${prefix}${s}"
  done < "$suggestions_file"
else
  cat "$suggestions_file"
fi
RELOAD_EOF
  chmod +x "$reload_script"

  local header="tab=complete │ ctrl-s=stash │ ctrl-n/b=cycle │ ctrl-f=full │ ctrl-r=ref │ enter=accept"
  [[ -n "$context_label" ]] && header="$context_label │ $header"

  local preview_args="'$query_file' '$input_file' '$NBX_DIR/slots' '' '$lib_dir' '$stash_file' '$stash_idx_file'"

  local result
  result=$(cat "$suggestions_file" | \
    fzf \
      --print-query \
      --expect "ctrl-h" \
      --query "$initial_query" \
      --preview "$preview_script $preview_args" \
      --preview-window "bottom:45%:wrap" \
      --header "$header" \
      --bind "change:execute-silent(printf '%s' {q} > '$query_file')+execute-silent(echo 0 > '$stash_idx_file')+reload($reload_script {q} '$suggestions_file' '$stash_file')+refresh-preview" \
      --bind "tab:transform(case {} in '[S'*) q=\$(echo {} | sed 's/^\[S[0-9]*\] //; s/  [0-9].*//'); echo \"change-query(\$q)+refresh-preview\" ;; *) echo replace-query ;; esac)" \
      --bind "ctrl-s:transform(bash '$stash_script' save '$query_file' '$input_file' '$NBX_DIR/slots' '$lib_dir' '$stash_file' '$stash_idx_file' '$reload_script' '$suggestions_file')" \
      --bind "ctrl-n:transform(bash '$stash_script' cycle +1 '$stash_file' '$stash_idx_file' '$query_file')" \
      --bind "ctrl-b:transform(bash '$stash_script' cycle -1 '$stash_file' '$stash_idx_file' '$query_file')" \
      --bind "ctrl-r:execute(fzf --no-sort --header 'jq quick reference │ ctrl-c=close' < '$cheatsheet' > /dev/tty)" \
      --bind "ctrl-f:execute(bash '$preview_script' '$query_file' '$input_file' '$NBX_DIR/slots' full '$lib_dir' '$stash_file' '$stash_idx_file' | less -RX > /dev/tty)" \
      --bind "ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up" \
    )
  local fzf_exit=$?

  # Clean up stash cycling state
  rm -f "$NBX_DIR/.query.orig"

  # --print-query + --expect: line 1 = query, line 2 = key, line 3 = selected
  local query key
  query=$(sed -n '1p' <<< "$result")
  key=$(sed -n '2p' <<< "$result")

  # ctrl-c/esc = exit 130, empty query = cancel
  [[ "$fzf_exit" -eq 130 ]] && return 1
  [[ -z "$query" ]] && return 1

  # Signal hidden via special prefix that the caller strips
  if [[ "$key" == "ctrl-h" ]]; then
    echo "HIDE:$query"
  else
    echo "$query"
  fi
}

# --- Focus mode query editor ---

nbx_fzf_focus() {
  local input_file="$1"
  local initial_query="${2:-.}"
  local step_num="$3"
  local editing_slot="$4"
  local pinned_slot="$5"
  local lib_dir
  lib_dir="${BASH_SOURCE[0]%/*}"
  local cheatsheet="$lib_dir/cheatsheet.txt"

  # Suggestions (same as nbx_fzf_query)
  local suggestions_file="$NBX_DIR/.suggestions"
  awk '/^[^#]/ && NF { sub(/  +.*/, ""); print }' "$cheatsheet" > "$suggestions_file"
  local slot_name
  for slot_name in $(nbx_list_slots); do
    echo "\$${slot_name}" >> "$suggestions_file"
  done
  (nbx_build_suggestions "$input_file" >> "$suggestions_file") &

  local query_file="$NBX_DIR/.query"
  echo "$initial_query" > "$query_file"

  # Focus preview: shows editing step result + pinned step result after replay
  local preview_script="$NBX_DIR/.focus_preview.sh"
  cat > "$preview_script" <<'PREVIEW_EOF'
#!/usr/bin/env bash
query_file="$1"
input_file="$2"
slots_dir="$3"
lib_dir="$4"
editing_slot="$5"
pinned_slot="$6"
NBX_DIR="${slots_dir%/slots}"
export NBX_DIR

source "$lib_dir/lib-state.bash"
source "$lib_dir/lib-jq.bash"
source "$lib_dir/lib-display.bash"
source "$lib_dir/lib-deps.bash"

query=$(cat "$query_file")
err_file="$NBX_DIR/.preview_err"

# --- Editing step result ---
nbx_build_slot_args
_DIM=$'\033[2m' _RST=$'\033[0m' _BOLD=$'\033[1m' _CYAN=$'\033[36m' _DIM_CYAN=$'\033[2;36m'
echo "${_DIM}── editing ${_BOLD}[\$editing_slot]${_RST}${_DIM} ──${_RST}"

result=$(jq -C "${NBX_JQ_ARGS[@]}" "${NBX_JQ_UNWRAP}${query}" "$input_file" 2>"$err_file" | head -80)
if [ -s "$err_file" ]; then
  warn "$(head -3 "$err_file")"
  [ -n "$result" ] && echo "$result"
elif [ -n "$result" ]; then
  echo "$result"
else
  info "(no results)"
fi

# --- Pinned step result (replay chain) ---
# Save editing step result to temp slot for replay
temp_slot="$slots_dir/${editing_slot}.json"
temp_backup=""
[ -f "$temp_slot" ] && { temp_backup=$(cat "$temp_slot"); }
jq "${NBX_JQ_ARGS[@]}" "${NBX_JQ_UNWRAP}${query}" "$input_file" > "$temp_slot" 2>/dev/null

# Find and replay steps between editing slot and pinned slot
echo ""
echo "${_DIM_CYAN}── pin: ${_BOLD}\$${pinned_slot}${_RST}${_DIM_CYAN} (via replay) ──${_RST}"

# Replay transitive dependents of editing_slot that lead to pinned_slot
depth=0
for f in "$NBX_DIR/history"/*; do
  [ -f "$f" ] && depth=$((depth + 1))
done

# Simple approach: replay all steps that depend on editing_slot, in order
for i in $(seq 1 "$depth"); do
  step_input=$(cut -f1 "$NBX_DIR/history/$i" 2>/dev/null)
  step_query=$(cut -f2 "$NBX_DIR/history/$i" 2>/dev/null)
  step_slot=$(cut -f3 "$NBX_DIR/history/$i" 2>/dev/null)
  step_type=$(cut -f4 "$NBX_DIR/history/$i" 2>/dev/null)

  [ "$step_slot" = "$editing_slot" ] && continue
  [ "$step_type" = "input" ] && continue
  [ ! -f "$step_input" ] && continue

  # Only replay if this step depends (directly or indirectly) on editing_slot
  case "$step_input" in
    *"/slots/${editing_slot}.json") ;;
    *)
      # Check if query references a slot we've already replayed
      needs_replay=false
      for dep_slot in $(echo "$step_query" | grep -oE '\$[a-zA-Z_][a-zA-Z0-9_]*' | sed 's/\$//'); do
        [ "$dep_slot" = "$editing_slot" ] && { needs_replay=true; break; }
      done
      $needs_replay || continue
      ;;
  esac

  nbx_build_slot_args
  jq "${NBX_JQ_ARGS[@]}" "${NBX_JQ_UNWRAP}${step_query}" "$step_input" > "$slots_dir/${step_slot}.json" 2>/dev/null
done

# Show pinned result
pinned_file="$slots_dir/${pinned_slot}.json"
if [ -f "$pinned_file" ]; then
  jq -C '.' "$pinned_file" 2>/dev/null | head -80
else
  info "(pinned slot not found)"
fi

# Restore original slot data (preview is read-only)
if [ -n "$temp_backup" ]; then
  echo "$temp_backup" > "$temp_slot"
fi
PREVIEW_EOF
  chmod +x "$preview_script"

  # Reload script (same as query editor)
  local reload_script="$NBX_DIR/.reload.sh"
  cat > "$reload_script" <<'RELOAD_EOF'
#!/usr/bin/env bash
q="$1"
suggestions_file="$2"
prefix=$(echo "$q" | sed -n 's/\(.*[|(] *\).*/\1/p')
if [ -n "$prefix" ]; then
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    echo "${prefix}${s}"
  done < "$suggestions_file"
else
  cat "$suggestions_file"
fi
RELOAD_EOF
  chmod +x "$reload_script"

  local header="focus [$step_num] → \$$editing_slot │ pin: \$$pinned_slot │ enter=apply │ ctrl-p=switch │ ctrl-d/u=scroll │ esc=exit"

  local result
  result=$(cat "$suggestions_file" | \
    fzf \
      --print-query \
      --expect "ctrl-p" \
      --query "$initial_query" \
      --preview "$preview_script '$query_file' '$input_file' '$NBX_DIR/slots' '$lib_dir' '$editing_slot' '$pinned_slot'" \
      --preview-window "right:60%:wrap" \
      --header "$header" \
      --bind "change:execute-silent(printf '%s' {q} > '$query_file')+reload($reload_script {q} '$suggestions_file')+refresh-preview" \
      --bind "tab:replace-query" \
      --bind "ctrl-r:execute(fzf --no-sort --header 'jq quick reference │ ctrl-c=close' < '$cheatsheet' > /dev/tty)" \
      --bind "ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up" \
    )
  local fzf_exit=$?

  local query key
  query=$(sed -n '1p' <<< "$result")
  key=$(sed -n '2p' <<< "$result")

  [[ "$fzf_exit" -eq 130 ]] && return 1
  [[ -z "$query" ]] && return 1

  if [[ "$key" == "ctrl-p" ]]; then
    echo "SWITCH:$query"
  else
    echo "$query"
  fi
}

# --- Row picker ---

# Build a jq index filter from index-prefixed fzf output lines
# Input: lines like "0:{...}\n2:{...}"
# Output: ".[0]" for single, "[.[0], .[2]]" for multiple
_nbx_pick_indices_to_filter() {
  sed 's/:.*//' | jq -R -s '
    split("\n") | map(select(length>0) | tonumber) |
    if length == 1 then ".[" + (.[0] | tostring) + "]"
    else "[" + (map(".[" + tostring + "]") | join(", ")) + "]"
    end
  ' | jq -r '.'
}

nbx_fzf_pick() {
  local input_file="$1"

  local lines
  lines=$(jq -r 'if type == "array" then to_entries[] | "\(.key):\(.value | tojson)" else "0:\(. | tojson)" end' "$input_file" 2>/dev/null)
  [[ -z "$lines" ]] && { warn "Nothing to pick from"; return 1; }

  local selected
  selected=$(echo "$lines" | \
    fzf --multi \
      --preview "echo {} | sed 's/^[0-9]*://' | jq -C '.'" \
      --preview-window "right:50%:wrap" \
      --header "Select rows │ tab=toggle │ enter=confirm" \
    ) || return 1

  [[ -z "$selected" ]] && return 1
  echo "$selected"
}

# --- Cheatsheet ---

# --- Show pager ---

# Show a single slot: route to array or raw pager
nbx_fzf_show_slot() {
  local step="$1" slot_name="$2"
  local slot_file="$NBX_DIR/slots/${slot_name}.json"
  local stype
  stype=$(nbx_slot_type "$slot_name")

  if [[ "$stype" == "array" ]]; then
    nbx_fzf_show_array "$step" "$slot_name" "$slot_file"
  else
    nbx_fzf_show_raw "$step" "$slot_name" "$slot_file"
  fi
}

# Array: rows as fzf items, full object detail in preview
# Outputs "PIN" or "EDIT" to stdout based on key pressed.
nbx_fzf_show_array() {
  local step="$1" slot_name="$2" slot_file="$3"
  local rows
  rows=$(nbx_slot_rows "$slot_name")
  local header="[$step] \$$slot_name ($rows rows) | /=search | enter=expand | ctrl-p=pin | ctrl-e=edit | esc=close"

  local result
  result=$(jq -r 'to_entries[] | "\(.key):\(.value | tojson)"' "$slot_file" 2>/dev/null | \
    fzf --no-sort \
      --print-query --expect "ctrl-p,ctrl-e" \
      --delimiter ':' \
      --preview "jq -C '.[ {1} ]' '$slot_file'" \
      --preview-window "right:50%:wrap" \
      --header "$header" \
      --bind "enter:execute(jq -C '.[ {1} ]' '$slot_file' | less -RFX > /dev/tty)" \
      --bind "ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up" \
    ) || return 0

  local key
  key=$(sed -n '2p' <<< "$result")
  [[ "$key" == "ctrl-p" ]] && echo "PIN"
  [[ "$key" == "ctrl-e" ]] && echo "EDIT"
}

# Non-array: pretty-printed colored JSON, searchable/scrollable
# Outputs "PIN" or "EDIT" to stdout based on key pressed.
nbx_fzf_show_raw() {
  local step="$1" slot_name="$2" slot_file="$3"
  local stype
  stype=$(nbx_slot_type "$slot_name")
  local header="[$step] \$$slot_name ($stype) | /=search | enter=expand | ctrl-p=pin | ctrl-e=edit | esc=close"

  local result
  result=$(jq -C '.' "$slot_file" 2>/dev/null | \
    fzf --ansi --no-sort \
      --print-query --expect "ctrl-p,ctrl-e" \
      --header "$header" \
      --bind "enter:execute(jq -C '.' '$slot_file' | less -RFX > /dev/tty)" \
    ) || return 0

  local key
  key=$(sed -n '2p' <<< "$result")
  [[ "$key" == "ctrl-p" ]] && echo "PIN"
  [[ "$key" == "ctrl-e" ]] && echo "EDIT"
}

# Multiple slots: picker with preview, enter opens detail
nbx_fzf_show_multi() {
  local entries=("$@")

  local items=()
  local e
  for e in "${entries[@]}"; do
    local step="${e%%:*}" slot_name="${e#*:}"
    local rows stype
    rows=$(nbx_slot_rows "$slot_name")
    stype=$(nbx_slot_type "$slot_name")
    items+=("[$step] \$$slot_name  ($rows $stype)")
  done

  local slots_dir="$NBX_DIR/slots"
  local picked
  picked=$(printf '%s\n' "${items[@]}" | \
    fzf --no-sort \
      --preview "name=\$(echo {} | sed 's/.*\\\$//; s/ .*//'); jq -C '.' '$slots_dir/'\"\$name\"'.json' 2>/dev/null | head -50" \
      --preview-window "right:50%:wrap" \
      --header "Pick slot to inspect | enter=open | esc=close" \
    ) || return 1

  [[ -z "$picked" ]] && return 1

  local step slot_name
  step=$(echo "$picked" | sed 's/\[//; s/\].*//')
  slot_name=$(echo "$picked" | sed 's/.*\$//; s/ .*//')

  echo "$step:$slot_name"
}

# --- Cheatsheet ---

nbx_show_ref() {
  local mode="${1:-quick}"
  local lib_dir
  lib_dir="${BASH_SOURCE[0]%/*}"
  local cheatsheet="$lib_dir/cheatsheet.txt"

  if [[ "$mode" == "full" ]]; then
    { cat "$cheatsheet"; echo ""; echo "# jq Manual"; echo ""; jq --help 2>&1; } | \
      fzf --no-sort --header "jq reference (curated + manual) │ ctrl-c=close"
  else
    fzf --no-sort --header "jq quick reference │ ctrl-c=close" < "$cheatsheet"
  fi
}
