# nbx — Interactive jq notebook

CLI-first notebook for exploring JSON/CSV files. Uses `.ipynb` format but no Jupyter runtime — just bash, jq, and fzf.

## Install

**zinit** (as a command on your `$PATH`)

```sh
zinit ice as"command" pick"bin/nbx"
zinit light mracos/nbx
```

or inside a `zinit for` block:

```sh
pick"bin/nbx" mracos/nbx
```

**Clone + PATH**

```sh
git clone https://github.com/mracos/nbx ~/.nbx
export PATH="$HOME/.nbx/bin:$PATH"
```

## Requirements

- **bash** 3.2+ (macOS stock bash works)
- **[jq](https://jqlang.github.io/jq/)** - JSON query engine (required)
- **[fzf](https://github.com/junegunn/fzf)** - interactive query editor and pickers (required)

## What it does

- **Live query editor** — type jq expressions, see results update in real-time (fzf preview)
- **Autocomplete** — suggestions built from your data structure + common jq patterns
- **Named slots** — each query result is saved as `$s1`, `$s2`, etc. for chaining
- **Row selection** — pick specific rows from results with fzf multi-select
- **Pipeline** — pipe one slot's output into the next query
- **Notebook persistence** — save/load as `.ipynb`, viewable on GitHub and VS Code
- **jq cheatsheet** — built-in reference, accessible mid-query with ctrl-r

## Usage

```bash
# Ephemeral session (no save)
nbx users.json orders.json

# With a notebook file (save/load)
nbx analysis.ipynb users.json orders.json

# Resume a saved analysis
nbx analysis.ipynb

# Start from a command's output (any non-file arg is run as a command)
nbx 'gh api /user/repos'             # quote it; repeatable

# Just the cheatsheet
nbx ref
nbx ref full    # includes jq --help
```

### Command sources

A command source is just a source whose data comes from a command's stdout,
labelled `cmd1`, `cmd2`, … Two ways to make one:

```bash
nbx 'gh api /user/repos'           # launch arg → source "cmd1"
```
```
nbx› query gh api /user/repos      # in-REPL    → source "cmd1", then jq editor
```

At launch, any positional arg that isn't an existing file (or `.ipynb`) is run as
a command (quote it so the shell passes it as one arg). In the REPL, `query`
takes a command in the same slot as a file or `$slot`: it captures the source and
opens the jq editor on it in one step. Once made, a command source behaves like
any file source: `query cmd1`, `show`, `refresh cmd1`, etc.

nbx does not read piped input (`cmd | nbx`): a pipe gives no command, so the
source could not be refreshed. Pass the command as an arg instead.

Persistence (see [ADR 0010](docs/adrs/0010-nbx-command-sources.md)):

- **Every source is snapshotted into the `.ipynb`** (`metadata.nbx.command_sources`)
  — command sources *and* file sources. A saved notebook is fully self-contained:
  hand someone just the `.ipynb` and they can view, re-query, and `refresh` with
  none of the original files present. On reload a live file at its original path
  wins; the snapshot is the offline fallback. nbx never runs shell on open.
- **Command sources also store their command**, so `refresh [source]` re-runs it
  in-session, re-captures the output, marks dependent steps stale, and the new
  snapshot is written on the next `save`. (File sources carry `command: null`.)

```
refresh            Re-run all command sources
refresh cmd1       Re-run just that source
```

**Non-JSON output is auto-wrapped.** jq only speaks JSON, so if a command emits
plain text, nbx wraps its lines into a JSON string array (`["line1","line2",…]`)
so the source is immediately queryable (`.[] | select(test("..."))`). Real JSON
and NDJSON pass through untouched. For structured text (CSV, columns), still
convert in the command for richer shape, e.g. `nbx 'mlr --icsv --ojson cat x.csv'`
or `nbx 'ps aux | tail -n+2 | jq -Rn "[inputs|split(\" +\";\"\")]"'`.

## Commands

| Command | Short | What |
|---------|-------|------|
| `query [file\|$slot\|cmd]` | `q` | Pick source (or run a command), write jq filter with live preview |
| `pick [$slot]` | | Select specific rows from results |
| `show [slot...]` | `s` | View slot contents (fzf pager) |
| `show -l` | | List all slots with compact preview |
| `refresh [source]` | | Re-run a command source, re-capture (no arg = all) |
| `edit N` | `e` | Re-edit step N (focus mode when pinned) |
| `delete [N]` | `d` | Delete step N (no arg = last step) |
| `ref [full]` | `r` | jq cheatsheet |
| `save` | | Save notebook to .ipynb |
| `reset` | | Clear notebook |
| `help` | `h` | Show commands |
| `quit` | | Exit (prompts to save if dirty) |

## Query editor keybindings

| Key | Action |
|-----|--------|
| Type | jq expression with live preview |
| Tab | Insert selected suggestion into query |
| Ctrl-r | Open jq cheatsheet |
| Enter | Accept query |
| Ctrl-c | Cancel |

## Architecture

```
files/shell/bin/nbx              Entry point + REPL loop
lib/shell/nbx/
├── lib-repl.bash                Command dispatch, banner, prompts
├── lib-state.bash               In-memory state: slots, history, dirty flag
├── lib-ipynb.bash               .ipynb v4 read/write (pure jq)
├── lib-fzf.bash                 Live-preview query editor, pick, cheatsheet UI
├── lib-jq.bash                  jq invocation + result typing
├── lib-deps.bash                Dependency tracking + staleness (ADR 0007)
├── lib-bulk.bash                `bulk` reset + replay
├── lib-display.bash             plain/info/warn/result helpers
├── repl/nbx-cmd-*               One file per REPL command (query, pick, edit, replay, …)
└── cheatsheet.txt               Curated jq reference
test/                            bats + busted (250+ tests across lib-* and repl/)
```

**State model:** Temp directory with `slots/` (named JSON files) and `history/` (numbered TSV entries). Each history entry: `input\tfilter\tslot\ttype`.

**Persistence:** `.ipynb` v4 format, read/written with pure jq. Each cell stores nbx metadata (`slot`, `type`, `input`, `filter`) in `metadata.nbx`. On load, cells are re-executed against source files; falls back to cached output if sources are missing.

**Save model:** Actions save a draft to `$JQX_DIR/.draft.ipynb` (temp, auto-cleaned). The actual `.ipynb` file is only written on explicit `save` or confirmed on `quit`.

## Dependencies

- bash
- jq
- fzf

## Design decisions

See `docs/adrs/nbx/`:

- [0001](docs/adrs/0001-nbx-bash-fzf-over-tui-frameworks.md) — Bash + fzf over TUI frameworks
- [0002](docs/adrs/0002-nbx-ipynb-format-over-custom.md) — .ipynb format over custom
- [0003](docs/adrs/0003-nbx-no-jupyter-runtime.md) — No Jupyter runtime dependency
- [0004](docs/adrs/0004-nbx-draft-save-over-autosave.md) — Draft save over autosave
- [0005](docs/adrs/0005-nbx-unified-slots-over-separate-inputs.md) — Unified slots over separate inputs
- [0006](docs/adrs/0006-nbx-replayable-pick.md) — Replayable pick
- [0007](docs/adrs/0007-nbx-dependency-tracking-staleness-replay.md) — Dependency tracking, staleness, replay
- [0008](docs/adrs/0008-nbx-reactive-exploration-ui.md) — Reactive exploration UI
- [0009](docs/adrs/0009-nbx-pluggable-engines.md) — Pluggable engines
- [0010](docs/adrs/0010-nbx-command-sources.md) — Command sources (positional arg / `query`, snapshot + refresh)

## How it started

Started as "make me a small CLI to play with JSON files using jq." Evolved through:

1. **Query scratchpad** — fzf with live jq preview, named slots for chaining
2. **Notebook feel** — visible step history, row selection (`pick`), edit-and-rerun
3. **Persistence** — `.ipynb` format for save/load, no Jupyter runtime
4. **Extraction candidate** — designed to eventually become a standalone tool (`mracos/nbx`)

The key insight: Jupyter notebooks are the right *format* but the wrong *runtime* for this use case. nbx uses the format for portability while providing a data-aware UX that Jupyter frontends don't offer (live preview, structure autocomplete, row picking).

## Future

Short term:

- `source N file` to change which file a step queries against, re-run it.
- `move N M` to reorder steps and re-run from the earliest affected position (dependency graph later, if needed).
- REPL tab completion for slot names in `show`, `rename`, `query $`, etc.
- Clean up magic strings: replace raw `cut -f3`, ANSI codes, format strings with named constants/helpers.
- CSV/TSV backend via miller (`mlr`). Per-cell backend selection. See [ADR 0009](../docs/adrs/0009-nbx-pluggable-engines.md).

Medium term:

- Multiple backends: each cell declares its engine (jq, mlr, sql, bash). Query editor adapts per backend.
- Markdown cells for notes between steps (already supported by `.ipynb`).
- Export pipeline as a standalone shell script.

Long term:

- Extract to standalone repo `mracos/nbx` (launcher/mcp extraction pattern).
- SQL backend via duckdb.

Ideas:

- `ai` engine for cells. Pipe slot data as context, write a natural language prompt instead of a filter. Simplest v0: shell out to `claude --print`. Cache responses in cell output; `edit N` re-sends.
- AI-assisted query writing: keybinding in the fzf query editor (e.g. `ctrl-a`) to generate a filter expression from natural language, insert into query field for live preview.
