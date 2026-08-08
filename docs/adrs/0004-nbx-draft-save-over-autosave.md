# 0004: nbx — Draft save over autosave

**Date:** 2026-04-05
**Status:** Accepted
**Deciders:** Marcos

## Context

nbx auto-saved the `.ipynb` file after every action (query, pipe, pick, back, reset). This meant every keystroke-level experiment was permanently written to the notebook file.

## Decision

**Incremental saves go to a draft sidecar. The notebook file is only written on explicit `save` or confirmed on `quit`.**

## How It Works

- Every action writes to `$NBX_DIR/.draft.ipynb` (temp dir, auto-cleaned on exit)
- `save` command writes to the actual `.ipynb` file and clears the dirty flag
- On quit with unsaved changes: prompts "Save? [Y/n]"
- Declining shows the draft location for manual recovery

## Rationale

- Exploratory analysis involves dead ends — you don't want every failed experiment saved
- Explicit save gives the user control over what the "checkpoint" is
- Draft sidecar provides crash recovery without polluting the real file
- Matches how editors work: you edit freely, save deliberately

## Rejected

- **Auto-save to `.ipynb` on every action** — too aggressive, saves noise
- **No draft at all** — loses work on crash
