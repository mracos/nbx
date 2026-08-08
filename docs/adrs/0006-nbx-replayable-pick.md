# 0006: nbx — Replayable pick via index filters

**Date:** 2026-04-11
**Status:** Accepted
**Deciders:** Marcos

## Context

`pick` lets users interactively select rows from a slot using fzf multi-select. The selected data gets saved to a new slot, and the step is recorded in history with type `"pick"`.

The problem was persistence. Pick steps need to survive two different replay paths: notebook save/load (ipynb) and bulk edit. Each path has different constraints.

Early implementation stored the filter as `"picked N"` (a human-readable label). This was opaque — ipynb_load couldn't re-execute it if the cached output was missing, and bulk had no way to represent it.

## Options Considered

1. **Always require cached output** — pick steps are never re-executed, only restored from the notebook's output cells.
2. **Store jq index filter** — record `[.[0], .[2]]` as the pick filter, same as any query. Cacheable in ipynb output, re-executable as fallback.
3. **Store selected indices as metadata** — keep indices in a sidecar field, reconstruct on load.

## Decision

**Option 2: Store jq index filter.**

`nbx_fzf_pick` converts selected row indices into a jq expression like `[.[0], .[2]]`. This filter is stored as the step's query in history and persisted in the ipynb cell's `metadata.nbx.filter`.

## How It Works

**Interactive pick:**
1. User runs `pick $s1`
2. fzf shows rows, user selects with tab
3. `_nbx_pick_indices_to_filter` converts selected indices → `[.[0], .[2]]`
4. Both the filter and the selected data are saved; filter recorded in history as type `"pick"`

**Notebook save/load (ipynb):**
- **Save:** The filter goes into `metadata.nbx.filter`, the selected data into the cell's `outputs[0].text` as cached output.
- **Load:** Primary path restores from cached output (fast, no re-execution). If cache is missing or invalid, falls back to re-executing the jq filter against the source slot — same code path as query steps.

**Bulk edit:**
- Pick steps render as normal query lines: `$source -> [.[0], .[2]] -> $slot`.
- On replay, the jq filter re-executes against the source slot — same code path as any other step. No special-casing, no backup/restore needed.
- Users can edit pick filters in the bulk editor (change indices, reorder, remove).

**Legacy handling:** Old notebooks with `"picked N"` filters can't be re-executed. `ipynb_load` warns and skips these cells. They still load if cached output is present.

## Rationale

- Jq filters are the universal language in nbx — pick shouldn't be a special case
- Cached output is the primary restore path (fast), but having a re-executable filter means notebooks degrade gracefully when cache is missing
- The filter is human-readable and editable — `edit` on a pick step can show what was selected
- Bulk treats picks identically to queries — no special-case code, no backup/restore machinery

## Trade-offs Accepted

- Index-based filters are positional — if the source data changes order, the pick selects different rows. Acceptable because nbx operates on local files that don't change mid-session.
- Legacy `"picked N"` steps require manual re-pick. No automated migration.

## Rejected

- **Cache-only** — fragile, notebooks without outputs lose pick steps entirely. No fallback.
- **Metadata sidecar** — added a new concept (indices-as-metadata) that the jq filter already represents
