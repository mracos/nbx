#!/usr/bin/env bash
# nbx display: styling, output helpers, notebook table

# --- ANSI constants ---
_RST=$'\033[0m'
_DIM=$'\033[2m'
_BOLD=$'\033[1m'
_GREEN=$'\033[32m'
_CYAN=$'\033[36m'
_RED=$'\033[31m'
_YELLOW=$'\033[33m'
_DIM_CYAN=$'\033[2;36m'

# --- Style functions (return styled strings, no newline) ---

dim()       { printf '%s%s%s' "$_DIM" "$*" "$_RST"; }
bold()      { printf '%s%s%s' "$_BOLD" "$*" "$_RST"; }
slot()      { printf '%s$%s%s' "$_BOLD" "${1#\$}" "$_RST"; }
separator() {
  local w
  w=$(stty size < /dev/tty 2>/dev/null | cut -d' ' -f2)
  printf '%*s' "$(( ${w:-80} - 2 ))" '' | tr ' ' '─'
}

# --- Output functions (print with intent) ---

plain()  { echo "  $*"; }
info()   { echo "  $(dim "$*")"; }
warn()   { echo "  ${_YELLOW}⚠ $*${_RST}" >&2; }
result() { echo "  → $(slot "$1") ($2)"; }

# --- Notebook display ---

nbx_show_notebook() {
  local depth
  depth=$(nbx_history_depth)
  [[ "$depth" -eq 0 ]] && return

  local hidden_count=0
  if [[ -f "$NBX_DIR/.hidden" ]]; then
    hidden_count=$(wc -l < "$NBX_DIR/.hidden" | tr -d ' ')
  fi

  # Adapt to terminal width
  local term_width
  term_width=$(stty size < /dev/tty 2>/dev/null | cut -d' ' -f2)
  term_width=${term_width:-80}
  local usable=$((term_width - 2))  # 2 = left indent

  echo ""
  info "$(separator)"

  local i
  for ((i = 1; i <= depth; i++)); do
    local input query slot_name type label rows stype
    input=$(nbx_history_field "$i" input)
    query=$(nbx_history_field "$i" query)
    slot_name=$(nbx_history_field "$i" slot)
    type=$(nbx_history_field "$i" type)
    label=$(nbx_input_label "$input")
    rows=$(nbx_slot_rows "$slot_name")
    stype=$(nbx_slot_type "$slot_name")

    local color="$_GREEN"
    [[ "$type" == "pipe" ]] && color="$_CYAN"
    [[ "$type" == "pick" ]] && color="$_YELLOW"

    # Build prefix: [N] $slot <- source │
    # Build suffix: value preview or rows+type, plus tags
    local prefix suffix tags=""
    nbx_is_hidden "$i" && tags=" (hidden)"
    nbx_is_stale "$i" && tags="${tags} (stale)"
    nbx_is_failed "$i" && tags="${tags} (failed)"
    nbx_has_backup "$i" && tags="${tags} (edited)"

    prefix=$(printf '[%d] $%s <- %s │ ' "$i" "${slot_name#\$}" "$label")

    # Single scalar values: show inline value instead of rows+type
    local value_preview=""
    if [[ "$rows" -eq 1 ]] && [[ "$stype" == "string" || "$stype" == "number" || "$stype" == "boolean" ]]; then
      value_preview=$(head -c 60 "$NBX_DIR/slots/${slot_name#\$}.json" | tr -d '"')
      suffix=$(printf '  = %s%s' "$value_preview" "$tags")
    else
      suffix=$(printf '  %s %s%s' "$rows" "$stype" "$tags")
    fi

    # Filter: truncate at terminal edge, no padding if shorter
    local max_query=$((usable - ${#prefix} - ${#suffix}))
    [[ "$max_query" -lt 20 ]] && max_query=20
    local display_query="$query"

    [[ ${#display_query} -gt $max_query ]] && display_query="${display_query:0:$((max_query - 3))}..."

    if nbx_is_hidden "$i"; then
      echo "  $(dim "${prefix}${display_query}${suffix}")"
    elif nbx_is_failed "$i"; then
      printf '  %s%s%s%s%s%s%s\n' \
        "$_RED" "$prefix" "$_RST${_DIM}" "$display_query" "$_RST${_RED}" "$suffix" "$_RST"
    elif nbx_is_stale "$i"; then
      printf '  %s%s%s%s%s%s%s\n' \
        "$_DIM" "$prefix" "$_RST${_DIM}" "$display_query" "$_RST${_YELLOW}" "$suffix" "$_RST"
    else
      printf '  %s%s%s%s%s%s%s\n' \
        "$color" "$prefix" "$_RST" "$display_query" "$_DIM" "$suffix" "$_RST"
    fi
  done
  info "$(separator)"

  # Pinned slot preview
  nbx_show_pinned
}

NBX_PIN_LINES="${NBX_PIN_LINES:-10}"

nbx_show_pinned() {
  local pinned
  pinned=$(nbx_pinned_slot) || return 0
  [[ -z "$pinned" ]] && return 0
  local slot_file="$NBX_DIR/slots/${pinned}.json"
  [[ -f "$slot_file" ]] || return 0

  local rows stype step
  rows=$(nbx_slot_rows "$pinned")
  stype=$(nbx_slot_type "$pinned")
  step=$(nbx_slot_to_step "$pinned" 2>/dev/null || echo "?")

  plain "${_DIM_CYAN}pin:${_RST} $(bold "[$step]") $(slot "$pinned")  ${_DIM}($rows $stype)${_RST}"
  jq -C '.' "$slot_file" 2>/dev/null | head -"$NBX_PIN_LINES" | while IFS= read -r line; do
    echo "  ${_DIM}|${_RST} $line"
  done
  local total_lines
  total_lines=$(jq '.' "$slot_file" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$total_lines" -gt "$NBX_PIN_LINES" ]]; then
    info "| ... ($((total_lines - NBX_PIN_LINES)) more lines)"
  fi
  info "$(separator)"
}
