# 0003: nbx — No Jupyter runtime dependency

**Date:** 2026-04-04
**Status:** Accepted
**Deciders:** Marcos

## Context

After deciding on `.ipynb` format, the next question was whether to use Jupyter's runtime (kernels, kernel protocol) or run commands directly.

We evaluated euporie (terminal Jupyter frontend) with a bash kernel as an alternative to building nbx's own execution model.

## Evaluation of euporie + bash_kernel

**Installed and tested:**
```bash
uv tool install euporie --with bash_kernel
euporie-notebook
```

**Problems found:**
1. **Not keyboard-centric** — navigation felt mouse-oriented even in TUI mode. Hard to use efficiently.
2. **Kernel is global** — can't mix backends per cell (e.g., jq in cell 1, mlr in cell 2). Changing kernel changes all cells.
3. **No data-aware features** — no live preview while typing, no autocomplete from JSON structure, no row selection (fzf multi-select), no jq cheatsheet inline.
4. **Install weight** — Python venv, bash_kernel registration, kernel protocol. For what is essentially `bash -c "jq '.name' file.json"`.

## Decision

**No Jupyter runtime. nbx executes commands directly.**

Each cell is re-executed by nbx via `jq "$filter" "$input_file"`. No kernel, no server, no protocol. The `.ipynb` format is used purely as a data format.

## Rationale

- A jq filter on a local file doesn't need a kernel protocol
- Direct execution means zero latency, no background processes
- nbx's value is in the interactive editing UX (fzf preview, autocomplete, pick), not in the execution layer
- Bash + jq + fzf are the only dependencies — already present in the dotfiles
- Future backends (mlr, duckdb) can be added as different command templates without kernel infrastructure

## Trade-offs Accepted

- Can't run arbitrary Python/R/Julia in cells — by design, not a general notebook
- No stdin/stdout streaming — each cell runs to completion
- No cell-to-cell variable passing via kernel state — uses slot files instead (explicit, inspectable)

## Rejected

- **euporie + bash_kernel** — heavyweight, poor keyboard UX, no data-aware features
- **Jupyter console** — linear REPL, no cell structure, no visible history
- **jpterm** — early stage (328 stars), Textual-based, not ready for daily use
- **marimo** — browser-only, Python-only, no terminal mode
