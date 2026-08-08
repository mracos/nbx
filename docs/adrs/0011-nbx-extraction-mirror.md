# 0011: nbx extraction to a standalone mirror via GitHub Action

**Date:** 2026-08-07
**Status:** Accepted
**Deciders:** Marcos

## Context

nbx is the most extraction-ready tool in dotfiles (ADR nbx/0001–0010: clean dispatcher → lib → shared `lib-cli.bash`, only `bash`/`jq`/`fzf` deps, 100+ tests, 11 ADRs). We want it available as a standalone `mracos/nbx` repo without moving development out of the dotfiles monorepo.

This **revisits [tools/0001](../tools/0001-tools-multirepo.md)**, which in June 2026 chose to stay multi-repo with manual `lib-cli` sync and explicitly dropped a monorepo + `git filter-repo` extraction model as "not worth its cost", while noting "revisit if sync friction grows enough to matter." The drift below (285 vs 92 lines) is that trigger. ADR 0011 does **not** overturn tools/0001 wholesale: it runs a lighter, **scoped experiment on nbx only**: an append-only copy-assembler, not the heavy `filter-repo` machinery tools/0001 rejected. If it proves cheap and reliable, we replicate it to launcher/mcp and generalize; if not, it stays an nbx-only trial and tools/0001's manual-sync status quo holds for every other tool. So nbx is the **POC/pilot**, deliberately not a commitment to extract everything.

Two coupling problems block a clean extract:

1. **`lib-cli.bash` is vendored and has drifted.** dotfiles has 285 lines; the `mcp` and `launcher` copies are 92. "Sync by hand" (CLAUDE.md) has not held. Whatever extracts nbx must also solve "one source of truth for lib-cli."
2. **nbx's files span four directories** (`files/shell/bin/nbx`, `lib/shell/nbx/`, `test/{files,lib}/shell/**/nbx*`, `docs/adrs/nbx/`), and its dispatcher resolves paths against the dotfiles layout (`REPO_ROOT="${SCRIPT_DIR%/files/shell/bin}"`).

## Options Considered

1. **git submodule for lib-cli.** One `mracos/lib-cli` repo, submoduled into each consumer.
2. **git subtree split.** Extract a single prefix into the standalone repo, preserving history.
3. **Copy-assembler + append-only publish Action.** A script gathers nbx's files into the standalone layout (vendoring lib-cli), and an Action clones the mirror, overlays the freshly-assembled tree, and adds one commit per change (plain push, no force).

## Decision

**Option 3: append-only publish mirror, via a per-tool copy-assembler.** dotfiles stays the single source of truth; `mracos/nbx` is a generated, read-only mirror that gains one commit per publish. Never edit it directly.

nbx is the **POC**. Each tool gets its own `scripts/extract-<tool>.sh` (nbx first); we do not build a generic engine up front. Once two or three assemblers exist and the shared shape is obvious, the future direction is to promote tool repos to real homes (possibly git submodules of dotfiles), but **shared libs (`lib-cli.bash`) always stay copied/vendored**, never submoduled, because that is the one thing zinit can't recurse and the one thing that must be present the instant a repo is cloned. So the assembler's copy-the-shared-lib step is permanent even if everything else migrates.

### Why not submodules (option 1)

zinit installs zsh plugins with plain `git clone` and does **not** recurse submodules, so a submodule'd lib-cli lands empty unless every consumer adds an `atclone'git submodule update --init'` hook. Submodules also pin a commit, so a lib-cli change means bumping the pointer in every repo. Vendored real files "just work" with zinit; the drift problem is better solved by automating the copy than by adding submodule ceremony.

### Why not subtree split (option 2)

`git subtree split` extracts **one** directory prefix. nbx is spread across four, so a split can't gather it. Preserving per-file history isn't worth reshaping the monorepo around subtree boundaries; the mirror can carry a generated history instead.

### Mechanism

- **`scripts/extract-nbx.sh <build-dir>`**: pure assembler, no network. Produces the standalone layout:
  - `bin/nbx`: with source paths rewritten from `$REPO_ROOT/lib/shell/{nbx,shared}/…` to the standalone `$LIB_DIR/…` (the `mcp`/`launcher` convention: `REPO_ROOT="$(dirname "$SCRIPT_DIR")"`, `LIB_DIR="$REPO_ROOT/lib"`).
  - `lib/`: `lib-*.bash`, `repl/nbx-cmd-*`, `cheatsheet.txt` from `lib/shell/nbx/`, **plus `lib/lib-cli.bash` vendored from `lib/shell/shared/lib-cli.bash`** (this is the single-source propagation: the copy is generated, never hand-edited).
  - `test/`: nbx bats + a portable `test_helper`.
  - `docs/adrs/`: from `docs/adrs/nbx/`.
  - `README.md`, `LICENSE`, `.github/workflows/ci.yml` (bats on macOS + Linux).
- **`.github/workflows/publish-nbx.yml`**: on push touching nbx paths (or manual dispatch), run the assembler, clone the mirror, overlay the assembled tree (so the diff captures adds/edits/deletes), and add **one commit per publish** whose message is `sync dotfiles@<sha>` followed by the triggering dotfiles commit message. Plain push (append-only, no force); identical output is a no-op that skips the empty commit. Auth via a `DOTFILES_PUBLISH_REPOS` secret (a shared publish token, reusable by future tool mirrors, not nbx-specific).
- **A drift-check** (separate, small): CI fails if the vendored `lib-cli.bash` copies in-repo diverge, until they're all regenerated from the one source.

### Portability

Extraction targets Linux CI too, so BSD-only constructs are fixed **in dotfiles** (the source), not patched in the mirror. Done: `sed -i ''` in `nbx_stash_delete` replaced with an `awk` rewrite. The dispatcher path-rewrite is the only transform the assembler applies; everything else copies verbatim.

## Consequences

**Positive:**

- One command (or push) regenerates a clean, self-contained `mracos/nbx`; no manual extraction.
- lib-cli has a single source; the mirror always carries a fresh copy, so drift is impossible for nbx.
- The assembler is testable offline: run it, then run the extracted bats against the build dir. Only the push needs a secret.
- Establishes the pattern for extracting the next tool.

**Negative:**

- The mirror is generated, so `mracos/nbx` can't take PRs/issues-as-source (changes must land in dotfiles). Acceptable for a "published artifact."
- The mirror's history is a publish log: one commit per publish, subject `sync dotfiles@<sha>` with the real dotfiles message in the body. It is append-only and git-native (no force-push), but the per-commit subjects are synthetic and don't match dotfiles' one-to-one. Preserving the *actual* per-commit history would require a `git filter-repo` rewrite (deterministic, force-push-safe) instead of the assembler; deferred as heavier machinery. Revisit if nbx graduates to its own dev home.
- The dispatcher path-rewrite is a transform the assembler must keep in step with `bin/nbx`. Kept minimal (two `source` path prefixes).

## Setup required (one-time, by the operator)

1. Create an empty `mracos/nbx` repo.
2. Add a `DOTFILES_PUBLISH_REPOS` secret. The workflow's automatic `GITHUB_TOKEN` **cannot** be used: GitHub scopes it to the repo the workflow runs in (dotfiles), so it can't push to a different repo. Use a fine-grained PAT with `contents:write` on the mirror repos (shared across future tool mirrors, so scope it to the set you'll publish). A deploy key would work too but is per-repo and would need the workflow switched to SSH.
3. Choose the trigger (push-to-nbx-paths vs manual dispatch); default: both.

## Related Decisions

- [tools/0001](../tools/0001-tools-multirepo.md): stay multi-repo with manual `lib-cli` sync, and its dropped extraction model. This ADR is the scoped revisit it invited; it supersedes tools/0001 **for nbx only**, as a test, pending a decision to replicate or not.
- [0001](0001-nbx-bash-fzf-over-tui-frameworks.md): the dispatcher/lib structure that makes extraction cheap.
- CLAUDE.md "Shared Code Across Repos": the manual-sync rule this supersedes for nbx.
