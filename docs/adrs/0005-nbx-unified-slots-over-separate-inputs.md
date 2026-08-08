# 0005: nbx — Unified slots over separate inputs

**Date:** 2026-04-05
**Status:** Accepted
**Deciders:** Marcos

## Context

nbx needed a way for users to provide manual values (thresholds, names, IDs) and reference them in queries. Also needed the ability to reference one slot's value inside a query against a different source.

## Options Considered

1. **Separate concepts** — `$slots` for computed results, `@inputs` for manual values. Different prefix, different storage.
2. **Unified slots** — everything is a `$slot`. Manual values created with `set`, computed values from `query`/`pipe`/`pick`. Distinguished only by step type in the notebook.

## Decision

**Option 2: Unified slots.**

A slot is a named piece of data. Whether it came from a query, a pick, or manual input doesn't change how it's referenced. `$name` everywhere, matching jq's own variable syntax.

## How It Works

**Creating slots:**
- `query` / `pipe` / `pick` → computed slot
- `set name value` → manual slot (value stored as JSON)

**Referencing slots in queries:**
All existing slots are passed to jq as `--argjson` flags. In any expression, `$threshold`, `$s1`, etc. are available as jq variables:

```
set threshold 30
query users.json → .[] | select(.age > $threshold)
```

**Three roles a slot can play:**
- **Source** — data you query against: `query $s1`
- **Variable** — referenced inside expression: `select(.age > $threshold)`
- **Output** — where results go: `→ $s3`

**Notebook format:** Same `.ipynb` cell format. The `metadata.nbx.type` field distinguishes `"input"` from `"query"`, `"pipe"`, `"pick"`. On load, input cells restore the value directly; query cells re-execute the filter.

## Rationale

- One concept instead of two — simpler mental model
- `$` prefix matches jq's native variable syntax — no translation needed
- The notebook display already shows step type (query/input/pick) — visual distinction is there without a prefix
- Inputs that "never change" is a false guarantee — users might `set threshold 25` to update it

## Rejected

- **Separate `@inputs`** — added a concept that didn't earn its complexity. The only benefit (knowing provenance at a glance) is already provided by the notebook step display.
