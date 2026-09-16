# 0009: nbx — Pluggable engines (starting with miller)

**Date:** 2026-04-12
**Status:** Accepted
**Deciders:** Marcos

## Context

nbx only speaks jq on JSON. Users exploring CSV/TSV files must convert to JSON first, losing the ergonomic benefits of tabular query tools. The roadmap calls for per-cell backend selection (jq, mlr, sql, bash).

The challenge is interop: if different engines produce different formats, chaining steps across engines breaks. And different tools have different strengths — jq for nested JSON, miller for tabular streams, SQL for joins and aggregations.

## Options Considered

1. **Convert CSV to JSON at load time** — one engine (jq), format adapter at the boundary.
2. **Pluggable engines with JSON slots** — each engine handles its native format for queries, but outputs JSON. Interop is free because slots are always JSON.
3. **Pluggable engines with native-format slots** — slots carry their format (CSV, JSON, Parquet). Cross-engine chaining requires explicit conversion.
4. **sq as second engine** — jq-flavored SQL, reads CSV/JSON natively, `--arg` for variable injection.
5. **duckdb as only engine** — SQL for everything, reads all formats.

## Decision

**Option 2: Pluggable engines with JSON slots. mlr first, duckdb later.**

### Why not option 1

Locks nbx into jq-only. Miller's `filter $age > 30 then cut -f name,email` is more natural for tabular data than jq's `[.[] | select(.age > 30) | {name, email}]`. The engine abstraction costs ~5 functions per backend and pays off immediately.

### Why not option 3

Complexity explosion. Every command that reads slots needs format dispatch. Cross-engine chaining (mlr result → jq query) requires explicit conversion steps, breaking flow. Slots-as-JSON keeps the entire state layer unchanged.

### Why not option 4 (sq)

sq is stateful — requires `sq add` before any query. Cross-source joins on JSON files fail (both tables named "data" in SQLite scratch DB, collision error). Tested and confirmed broken for the exact interop use case we need.

### Why not option 5 (duckdb only)

SQL is verbose for quick filtering. DuckDB cold start is ~2x slower than jq/mlr per invocation (33ms vs 18ms on 10k rows). Works better as infrastructure (joins, output formatting) than as the primary interactive query language.

### Why mlr first, duckdb later

- **mlr** covers the immediate need: CSV/TSV input with fast, terse tabular filtering. Stateless, reads JSON natively (slot interop for free), 19ms on 10k rows.
- **duckdb** is the right tool for cross-slot joins (`JOIN '/path/to/slot.json'`), output formatting (`show --format table|csv|markdown`), and SQL queries. These aren't the current pain point. duckdb is additive — doesn't require reworking the engine contract.

Three engines in final state, each in its sweet spot:
- **jq**: nested JSON, tree traversal, functional transforms
- **mlr**: tabular data, stream filtering, quick exploration
- **sql** (duckdb): joins, aggregations, cross-slot queries, output formatting

## Engine Contract

Each engine lives in `lib/shell/nbx/engines/engine-<name>.bash`:

```bash
nbx_engine_<name>_detect()       # file → return 0 if this engine handles it
nbx_engine_<name>_exec()         # query, input_file, slot_name → run, save JSON to slot
nbx_engine_<name>_preview()      # query, input_file → colored output for fzf
nbx_engine_<name>_suggestions()  # input_file → autocomplete lines for fzf
nbx_engine_<name>_cheatsheet()   # → path to cheatsheet file
```

Engine detection: file extension (`*.csv/*.tsv` → mlr, else → jq). User override: `query $source -e mlr`.

## Slot Injection

Each engine maps nbx slots to its native variable mechanism:

| Engine | Scalar injection | Syntax in query | Array/object slots |
|--------|-----------------|-----------------|-------------------|
| jq | `--slurpfile` + unwrap preamble | `$slot_name` | Full support (all types) |
| mlr | `begin { @name = value; }` oosvar | `@slot_name` | As input only (not variables) |
| sql (future) | `SET VARIABLE name = value` | `getvariable('name')` | `JOIN '/path/to/slot.json'` |

The `$field` vs `@slot` distinction in mlr is natural: `$age` = column in current record (mlr native), `@threshold` = injected nbx slot (oosvar).

## History Format Change

Current: `input\tquery\tslot\ttype` (4 fields)
New: `input\tquery\tslot\ttype\tengine` (5 fields)

Missing 5th field defaults to `jq` (backward compat with existing notebooks).

History functions move from `lib-state.bash` to `lib-history.bash` with the TSV format documented in the file header.

## ipynb Format Change

Cell metadata gains `engine`:

```json
{
  "metadata": {
    "nbx": {
      "slot": "s1",
      "type": "query",
      "input": "/path/to/users.csv",
      "filter": "filter $age > 30 then cut -f name,email",
      "engine": "mlr"
    }
  },
  "source": ["mlr --icsv --ojson 'filter $age > 30 then cut -f name,email' users.csv"]
}
```

Missing `engine` field defaults to `jq` on load.

## Bulk Format Change

```
users.csv [mlr] -> filter $age > 30 then cut -f name,email -> $active
$active [jq] -> map(.name) | sort -> $names
orders.json -> .[] | select(.total > 100) -> $big_orders
```

`[engine]` tag is optional — defaults to `jq`.

## What Changes

| Layer | Change |
|-------|--------|
| `lib-state.bash` | History functions extracted to `lib-history.bash` |
| `lib-jq.bash` | Becomes `engines/engine-jq.bash` |
| `lib-fzf.bash` | Preview, suggestions, cheatsheet dispatch to engine |
| `lib-ipynb.bash` | Engine in metadata, dynamic source_cmd |
| `lib-bulk.bash` | Parse `[engine]` tag, dispatch exec |
| `lib-display.bash` | Show `[engine]` label after source |
| `nbx-cmd-query` | Parse `-e` flag, detect engine, dispatch |
| `nbx-cmd-replay` | Read engine from history, dispatch |
| `nbx-cmd-edit` | Engine-aware fzf editor |

Unchanged: pick, show, set, dup, hide, move, delete, rename, back, deps.

## Implementation status

Landed (2026-09-15), the smallest slice that makes CSV usable:

- `.csv`/`.tsv` files load as sources, converted with `mlr --i{csv,tsv} --ojson cat`
- The conversion is a command source (ADR 0010), so `refresh` re-reads the file and
  `save` snapshots the JSON. Label is the filename minus its extension
- A query re-converts a source whose file changed, since jq reads a JSON source
  live and a snapshot that only moves on `refresh` would answer from stale rows.
  Only for files converted in this session: re-running a command stored in a
  notebook would put shell back on the open path that ADR 0010 took it off
- Missing `mlr` skips the file with a warning; jq-on-JSON is unaffected

Not implemented: everything that makes the engine *pluggable*. Queries are still jq
only, so there is no `engine-<name>.bash` contract, no `-e` flag, no `[engine]` tag in
bulk, and no `engine` field in history or cell metadata. Those formats are unchanged,
which keeps the migration notes above valid for whenever the rest lands.

## Consequences

- CSV/TSV files work as first-class nbx sources
- Users choose the right query language for the data shape
- mlr is optional — missing mlr only disables CSV engine, jq still works
- Adding future engines (sql, bash) follows the same 5-function contract
- Existing notebooks load with `jq` default — no migration needed
