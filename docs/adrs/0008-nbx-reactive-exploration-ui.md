# 0008: nbx — Reactive exploration UI (show, pin, focus)

**Date:** 2026-04-12
**Status:** Accepted
**Deciders:** Marcos

## Context

nbx exploration is friction-heavy. Two pain points:

1. **Edit-inspect round trips.** Changing an upstream step requires: esc from current view, type `edit N`, re-enter fzf, accept, confirm replay, then `show` downstream to verify. The mental model is a reactive spreadsheet — change upstream, see downstream update — but the implementation is a sequential command REPL.

2. **Wall-of-text output.** `show` pipes through `less`. For large JSON you lose your bearings. No way to navigate individual rows, no way to go from viewing to editing without exiting and typing a new command. Scrolling in the query editor preview requires ctrl-f (opens full-screen `less`), breaking flow.

The underlying tension: the REPL model (type command, see result, type next command) doesn't match the exploration model (edit here, look there, tweak, look again).

## Options Considered

1. **Single fzf session as notebook navigator** — the notebook itself is an fzf list, steps are items, preview shows output. Edit via nested fzf.
2. **Enhanced REPL with in-fzf jumps** — keybindings inside fzf sessions to jump between steps. Each jump exits and re-enters fzf.
3. **Pin + focus model** — pin a downstream slot for persistent visibility, focus mode decouples the query editor from the preview target.
4. **tmux split** — separate panes, filesystem-based communication.

## Decision

**Option 3: Pin + focus, implemented in four incremental phases.**

Each phase is independently useful. Later phases build on earlier ones.

### Phase 1: Better show (fzf-as-pager)

Replace `less` with fzf. Array rows become fzf items with a detail preview pane. For objects/scalars, line-based fzf with the raw JSON.

```
+- rows --------------------+- detail ----------------------+
| 0: {"role":"admin"...}    | {                             |
| 1: {"role":"editor"..}    |   "role": "editor",           |
| 2: {"role":"viewer"..}    |   "count": 14,                |
|                           |   "members": ["Bob", "Diana"] |
+---------------------------+-------------------------------+
| $stats | arrow/search | enter=close                       |
+-----------------------------------------------------------+
```

Benefits: search inside results, navigate rows, detail pane for the selected item. Keybindings discoverable in the header.

### Phase 2: Pin

New commands: `pin [$slot|N]`, `unpin`. Pins a slot to a persistent bottom region in the REPL, below the notebook table, above the prompt.

```
  ------------------------------------------------
  [1] $users <- data.json | .users    120 array
  [2] $stats <- $users    | group_by  5 array
  ------------------------------------------------
  pin: $stats [2]  (5 array)
  | [{"role":"admin","count":12}, ...
  ------------------------------------------------

  dir notebook nbx> _
```

After any mutation (edit, query, set, undo, replay), auto-replay the chain and refresh the pinned area. The `p` keybinding in show pins the current slot — users discover pin from show.

### Phase 3: Focus mode

`focus N` opens the query editor for step N. If a slot is pinned, the preview pane splits: top shows the current step's result, bottom shows the pinned slot after replaying the chain.

```
+- completions ---+- preview ---------------------------+
|                 | -- editing [1] $users ------------- |
|                 | [{"name":"Ana"}, {"name":"Bob"}]    |
|                 | -- pin: [2] $stats (via replay) --- |
|                 | [{"role":"admin","count":8}]        |
+-----------------+-------------------------------------+
| focus [1] > $users | pin: $stats                      |
| jq> .users | map(select(.joined > "2024")) _         |
+-------------------------------------------------------+
```

Preview runs: apply filter, save temp slot, replay chain, render both. Debounce or "replay on accept only" for heavy chains.

### Phase 4: Navigation shortcuts

Wire the phases together:
- From show: `ctrl-e` opens focus on that step.
- From focus: `ctrl-p` switches which step you're editing (keeps pin).
- `focus N` auto-pins last step if nothing pinned.

## Rationale

- **Incremental delivery** — each phase ships independently and improves the experience. No big-bang rewrite.
- **fzf-as-pager over custom TUI** — consistent with ADR 0001. fzf provides search, preview, keybindings for free. The show pager is just another fzf session.
- **Pin over automatic watch** — explicit user control over what to track. "Watch" implies polling; "pin" implies "keep this visible." Lower cognitive overhead.
- **Focus reuses the query editor** — no new fzf session type. The existing `nbx_fzf_query` just gets a smarter preview script when a pin exists.
- **Phase ordering: show before pin** — show is a standalone win (fixes wall-of-text). Pin builds on it (the `p` keybinding in show is how users discover pin). Focus builds on pin. Navigation wires them together.

## Trade-offs Accepted

- **Preview latency in focus mode** — replaying a chain on every keystroke may be slow for long chains. Mitigation: debounce in the preview script, or "replay on accept" toggle. Acceptable for typical notebooks (5-30 steps with sub-second jq queries).
- **Single pin slot** — only one slot can be pinned. Multiple pins add complexity (which one shows in focus? how to lay out multiple?) for marginal gain. Start with one, extend if needed.
- **Pinned area is truncated** — the bottom region shows first N lines (configurable). Full inspection still uses show. Acceptable because pin is for "glance at downstream," not deep inspection.
- **fzf-as-pager loses `less` features** — no regex search on raw text, no line numbers. But gains row-level navigation and structured preview, which matters more for JSON.

## Rejected

- **Single fzf session (option 1)** — nested fzf (edit opens another fzf inside a running fzf) is fragile. The query editor needs its own completions, preview, and keybindings. Nesting that inside a navigator session is a maintenance burden.
- **tmux split (option 4)** — external dependency, heavier setup, two processes to coordinate. The pin model achieves the same visual result within a single terminal.
- **Automatic reactive replay (full spreadsheet)** — rejected in ADR 0007 and still rejected. Users want control over when expensive re-computation happens. Pin + focus gives the reactive *feel* with manual triggers.
