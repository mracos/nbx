# 0002: nbx — .ipynb format over custom file format

**Date:** 2026-04-04
**Status:** Accepted
**Deciders:** Marcos

## Context

nbx needs to save and reload analysis sessions. Each session is a sequence of steps (cells): source file + jq filter + output. Needed a file format for persistence.

## Options Considered

1. **Custom `.nbx` JSON format** — simple array of cells with nbx-specific schema.
2. **`.ipynb` (Jupyter Notebook v4)** — standard notebook format, JSON-based.
3. **Shell script** — each cell is a bash command, output in comments. Executable.
4. **Markdown with code blocks** — human-readable, but parsing is fragile.

## Decision

**Option 2: `.ipynb` format.**

nbx reads/writes `.ipynb` files using pure bash + jq. No Python runtime, no Jupyter, no kernels. Just the JSON format.

## Rationale

- `.ipynb` is JSON — trivially readable/writable with jq
- Viewable on GitHub (renders natively), VS Code, Jupyter, nbviewer
- Standard `cells` array with `source`, `outputs`, `metadata` maps directly to nbx's model
- nbx-specific data (slot name, filter, source file, step type) lives in `metadata.nbx` per cell
- Source files recorded in notebook-level `metadata.nbx.sources`
- If nbx ever becomes a standalone tool, the format is already portable
- No custom parser to maintain — it's just `jq '.cells[0].metadata.nbx.filter'`

## How It Works

```json
{
  "nbformat": 4,
  "metadata": {
    "nbx": { "version": "0.1", "sources": ["users.json"] },
    "kernelspec": { "name": "bash", "display_name": "Bash (nbx)" }
  },
  "cells": [{
    "cell_type": "code",
    "source": ["jq '.[] | select(.age > 30)' users.json"],
    "metadata": {
      "nbx": { "slot": "s1", "type": "query", "input": "users.json", "filter": ".[] | select(.age > 30)" }
    },
    "outputs": [{"output_type": "stream", "name": "stdout", "text": ["..."]}]
  }]
}
```

## Trade-offs Accepted

- `.ipynb` has fields nbx doesn't use (`execution_count`, `id`) — we set them minimally
- GitHub rendering shows raw shell commands, not the nbx notebook UI — acceptable
- Jupyter could technically open these but the bash kernel won't understand nbx metadata — that's fine, it's not the intended viewer

## Rejected

- **Custom `.nbx`** — another format to explain, no ecosystem benefits, same implementation effort
- **Shell script** — can't store outputs, no structured metadata
- **Markdown** — parsing code blocks is error-prone, no standard for metadata
