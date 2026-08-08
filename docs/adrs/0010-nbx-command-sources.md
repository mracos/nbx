# 0010: nbx command sources (positional arg / `query`, snapshot + refresh)

**Date:** 2026-07-23
**Status:** Accepted
**Deciders:** Marcos

## Context

nbx sources are files: `nbx users.json orders.json`. Most exploratory data does not start life as a file on disk. It comes out of a command: `gh api /repos`, `curl ...`, `kubectl get ... -o json`, a `psql -Ac`. Today the user must redirect to a tempfile first, then pass that file. That breaks the "just start exploring" flow and litters the cwd.

A command source is not a new kind of thing: it is a **source** (a root that data enters through), same as a file. Only its origin differs. So the model is "add a source whose bytes come from a command," and everything downstream (`query`, `refresh`, `save`) is unchanged. Introducing one has two surfaces:

- **Positional launch arg**: `nbx 'gh api /repos'`. A positional that is not an existing file (or `.ipynb`) is run as a command. No flag: sources are just args, whether files or commands. Repeatable.
- **In-REPL `query <command>`**: `query`'s arg is a file, a `$slot`, or a command. A command captures the source and opens the jq editor on it in one step. There is no separate `source` verb; `query` is the single verb for "explore this," whatever "this" is.

Keeping the command *inside* nbx is what makes reproducibility possible, so both surfaces store the command. **Piped stdin (`gh api /repos | nbx`) is deliberately not supported**: a pipe hands nbx bytes with no command attached, so the source could never be refreshed, and `nbx 'gh api /repos'` expresses the same thing while staying re-runnable. nbx detects a pipe and exits with a hint pointing at the arg form, rather than feeding the bytes to the REPL.

Three earlier revisions were dropped: a dedicated `-c 'CMD'` flag (file-or-command detection on the positional arg is one fewer concept); piped-stdin capture (the not-refreshable exception plus the fragile `exec < /dev/tty` REPL reconnect it required); and a standalone `source` verb (folded into `query`, since a command source always gets queried anyway, and one verb is simpler than two).

The hard question is persistence. A command's output is captured into a tempfile under `$NBX_DIR`; that path is meaningless after the session ends. When the notebook is saved and reloaded, what is the source?

## Options Considered

1. **Ephemeral only**: capture output at launch; on reload, sources are gone, cells fall back to cached output (existing "missing source" behavior). No new data model.
2. **Re-runnable command stored in the notebook**: persist the command string in `metadata.nbx`; on reload, re-execute it to rebuild the live source.
3. **Snapshot output into the notebook**: embed the captured JSON as an extra artifact so reload restores the exact bytes without re-running.

## Decision

**Option 3 by default for every captured source; option 2 (re-run) available on demand for command sources via `refresh`. Option 1 is never used.**

Reload must never execute shell the notebook carries, which removes the code-execution-on-open vector entirely. So the captured output is snapshotted into the `.ipynb` and restored verbatim on load. A `-c` source additionally stores its command, which turns re-fetching into an explicit, in-session action (`refresh`) rather than something that happens silently when a file is opened.

### Data model

- Capture (whether from a positional arg or `query <command>`) writes to `$NBX_DIR/sources/<label>` and registers the path in `NBX_FILES`. Labels are extensionless so they read as typeable source names: `cmd1`, `cmd2`, … The label counter picks the next free `cmdN`, so launch commands, in-REPL commands, and a reloaded notebook's own sources never collide. (Launch commands are captured *after* the notebook loads, so the notebook's stored `cmdN` claim their labels first.)
- Command sources also record `<label> \t <command>` in a `$NBX_DIR/.commands` state file. Bash 3.2 has no associative arrays, so this follows the existing file-backed state pattern (`.stash`, `.hidden`), not a `declare -A`.
- Capture dedups by command: an identical command string reuses its existing source (and its snapshot) rather than piling up `cmd2`, `cmd3`, … of the same thing. To re-fetch, use `refresh`. This means `query <cmd>` on a command already sourced just queries the existing snapshot.
- On save, **every** source becomes an entry in `metadata.nbx.command_sources`: `{ label, command, snapshot }` — command sources *and* file sources, so the notebook is fully self-contained (portable with none of the original files present). `snapshot` is the raw content; `command` is the recipe for command sources and `null` for file sources. Captured temppaths are filtered out of `metadata.nbx.sources` (the path list keeps only real external files, used to prefer a live file over its snapshot on reload).
- On load, each entry's `snapshot` is written back to `$NBX_DIR/sources/<label>` under the new session's `NBX_DIR`, with no shell run. A command source's `command` is re-recorded in `.commands` so `refresh` works. Cells resolve their input by **basename**, so a source matches across sessions even though the absolute path differs; a live file still present at its original path is preferred over its snapshot, which is the offline fallback. (The array is named `command_sources` for historical reasons though it now snapshots all source kinds; a rename is queued for the standalone extraction.)

### `query <command>` is the sole in-REPL entry

`query` accepts a command in the same arg slot as a file or `$slot`: if the arg does not resolve to an existing source or slot (and is not a `$slot` / step-number reference, which stay a hard "not found"), it is captured as a command source via `nbx_capture_one_command` and the jq editor opens on it. There is no separate `source` verb: a command source is always something you want to query, so folding ingestion into `query` removes a verb without removing a capability. Querying an already-captured source by label (`query cmd1`) reads its snapshot and never re-runs. This keystroke-level convenience is not the deeper unification of source and query as concepts, which waits on the per-cell engine model (ADR 0009).

### Refresh (option 2, on demand)

`refresh [source]` re-runs a command source's stored command, overwrites its snapshot in the session, marks every step that reads it (and their transitive dependents) stale, then offers to replay, reusing the existing staleness machinery (ADR 0007). The refreshed output is persisted on the next `save`. Every command source is refreshable (there is no non-refreshable source kind), and re-running is user-initiated and echoes the command, so it is not a silent-execution surface.

### Why not option 1 (ephemeral)

Losing the data on reload makes a saved notebook useless for anything a command produced, the common case. Cached cell output only covers cells that ran; the raw source is gone. Snapshotting the source is cheap and makes reload self-contained.

### Why snapshot despite the `.ipynb` bloat

Embedding captured bytes does grow the file and freezes a point-in-time copy. Accepted: reload is then fully offline and deterministic, and `refresh` covers "re-fetch fresh" when the user wants it. The storage cost buys a notebook that opens the same way on any machine with no network and no trust decision.

## Consequences

**Positive:**

- `gh api … | nbx` and `nbx -c '…'` start a session with no tempfile dance.
- Reload is self-contained and safe: no network, no shell execution, no trust prompt.
- Command sources stay reproducible on demand via `refresh`, wired into the existing stale/replay flow.
- No new runtime deps; capture is `cat`/`eval` into a tempfile, persistence is jq (already the .ipynb engine).

**Negative:**

- Snapshots bloat the `.ipynb` and duplicate data already present in cached cell outputs. Accepted for offline, deterministic reload.
- `refresh` runs stored shell, but only when the user asks and with the command echoed. A far smaller surface than auto-run-on-open.
- Command output should be JSON for jq. Non-JSON is not rejected: nbx wraps plain-text output into a JSON string array (one line per element) so the source stays queryable, and reports that it did. Real JSON and NDJSON pass through untouched. Structured text (CSV, columns) still queries better if the command converts it (`mlr --ojson`, `jq -Rn`), but the wrap keeps line-based text usable with zero ceremony. This is a stopgap until per-cell engines (ADR 0009) let a `sh`/`csv` engine own the parsing.

## Related Decisions

- [0005](0005-nbx-unified-slots-over-separate-inputs.md): sources and slots share one input namespace, so command sources need no new query path.
- [0009](0009-nbx-pluggable-engines.md): per-engine capture validation lands here once non-jq engines exist.
