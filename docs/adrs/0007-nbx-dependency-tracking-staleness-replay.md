# 0007: nbx — Dependency tracking, staleness, and replay

**Date:** 2026-04-11
**Status:** Accepted
**Deciders:** Marcos

## Context

nbx steps form dependency chains through slot references — a query on `$users` depends on the step that produced that slot. But the tool had no awareness of these dependencies. When `edit` updated a step, downstream steps kept stale data. The only recovery was `bulk`, which resets and replays the entire notebook.

Users needed incremental, targeted replay with visual feedback about what's outdated.

## Options Considered

1. **Stored dependency graph** — explicit `.deps` file tracking edges between steps.
2. **Computed dependency graph** — derive dependencies on the fly from existing history entries.
3. **Full reactive system** — automatic re-execution on any upstream change (spreadsheet model).

## Decision

**Option 2: Computed dependency graph with manual replay.**

Dependencies are derived from two sources already present in history entries:
- The `input` field: if it points to `$NBX_DIR/slots/X.json`, the step depends on slot `X`.
- The `query` field: `$slot_name` variable references matching known slots.

Slot names (not step numbers) are the canonical dependency identifiers — they're stable across step reordering via `move`.

## How It Works

**Dependency graph (`lib-deps.bash`):**
- `nbx_step_deps N` returns slot names step N depends on.
- `nbx_dependents NAME` finds steps that depend on a given slot.
- `nbx_transitive_dependents NAME` walks the full DAG via BFS.
- No storage overhead — computed from existing history entries.

**Staleness tracking:**
- `.stale` file in `$NBX_DIR`, newline-separated step numbers (same pattern as `.hidden`).
- `edit` marks all transitive dependents as stale after updating a step.
- `replay` clears the stale mark after re-executing a step.
- `nbx_show_notebook` renders stale steps with a `(stale)` tag and dimmed prefix.

**Replay (`nbx-cmd-replay`):**
- `replay N` — re-execute step N from its stored history, mark its dependents stale.
- `replay --stale` — re-execute all stale steps in ascending order (topologically correct since step numbers are already ordered).
- `replay --from N` — re-execute step N and all transitive dependents.
- Non-interactive: query/pipe steps re-run jq, pick steps re-apply stored index filters (same as `bulk`). No fzf prompts.

**ipynb persistence:**
- Stale steps are saved with `execution_count: null` (native ipynb semantics for "needs to run").
- On load, cells with `execution_count: null` are restored from cache but marked stale.
- Renders as `[ ]:` in GitHub and VS Code — free visual indicator, no custom metadata.

## Rationale

- Computed > stored: no sync issues, no new files to maintain. For typical notebooks (5-30 steps), scanning all entries is trivial.
- Slot names > step numbers: stable across `move`, human-readable, already the mental model users have.
- Manual replay > automatic: explicit control over when propagation happens. Avoids surprise re-execution of expensive queries or picks that need human judgment.
- `execution_count: null` for ipynb: standard Jupyter semantics, renders correctly everywhere, no custom metadata needed.

## Trade-offs Accepted

- Query-level dependency scanning uses regex matching against known slot names. A `$slot_name` that happens to appear in a string literal would be falsely detected. Acceptable because jq string literals rarely contain `$variable` patterns.
- Pick steps replay with stored index filters (e.g., `.[0], .[2]`). If source data changed order, different logical items get selected. Acceptable and consistent with `bulk` behavior.
- No automatic cascade — the user must run `replay --stale` manually. This is a feature, not a limitation.

## Rejected

- **Stored dependency graph** — adds a file that must stay in sync with history. Every operation that modifies history (delete, move, rename) would need to update deps too. The existing data already encodes the graph.
- **Automatic reactive replay** — too aggressive for a CLI tool operating on potentially large JSON files. Users want control over when expensive re-computation happens.
- **Custom ipynb metadata for staleness** — `execution_count: null` already does this and is understood by all notebook renderers.
