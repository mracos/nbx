# 0001: nbx — Bash + fzf over TUI frameworks

**Date:** 2026-04-03
**Status:** Accepted
**Deciders:** Marcos

## Context

Needed a CLI tool to interactively explore JSON/CSV files — build jq queries incrementally, chain results, compare outputs. The core workflow: "I have 5 JSON files in a folder, let me explore them."

## Options Considered

1. **Bash + tmux panes** — tmux splits for panels, fzf for selection. Lightweight but tmux dependency.
2. **Python (textual/rich)** — proper TUI with panels, live preview. Python already available via mise.
3. **Go (bubbletea)** — single binary, great TUI. But standalone project, not a dotfiles script.
4. **Full TUI in pure bash** — split screen, raw terminal mode, cursor positioning. ~500-800 lines.
5. **Sequential REPL** — numbered slots, step-by-step, display with `column`. ~200 lines.
6. **fzf-powered** — fzf's preview pane for live output, chain queries between invocations.

## Decision

**Option 6: fzf-powered, specifically a REPL loop (option 5) wrapping fzf sessions (option 6).**

The REPL manages state (slots, history, notebook display). Each interactive moment (query editing, row selection, cheatsheet browsing) launches fzf with the right configuration. Best of both: clean state management + powerful interactive editing.

## Rationale

- Bash + fzf + jq are already installed — zero new deps
- Fits dotfiles patterns (lib-cli.bash, USAGE headers, bats tests)
- fzf's `--preview` gives live jq output with zero custom rendering code
- REPL loop keeps state simple (files in a tmp dir)
- Each fzf invocation does one thing well
- ~370 lines total, maintainable

## Trade-offs Accepted

- No persistent split-screen view (bounce between REPL prompt and fzf windows)
- fzf's keybindings are fixed — can't add custom text-editing behavior
- Limited to what fzf can render (no rich tables, no color beyond what jq outputs)

## Rejected

- **tmux dependency** — not everyone runs tmux, adds coupling
- **Python/Go TUI** — too heavy for a dotfiles tool, different build/install pattern
- **Pure bash TUI** — 500+ lines of terminal management code for diminishing returns
