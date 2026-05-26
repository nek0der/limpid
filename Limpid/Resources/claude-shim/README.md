# claude-shim

A pair of small POSIX-shell scripts that let Limpid resume Claude Code
sessions across app restarts without ever writing to the user's
`~/.claude/settings.json`.

## Files

- `claude` — a transparent wrapper installed at
  `Limpid.app/Contents/Resources/claude-shim/claude`. Limpid prepends
  this directory to `PATH` for every pty it spawns, so when the user
  types `claude` inside a Limpid terminal this script runs first.
  It locates the real `claude` binary, then exec's it with
  `--settings '<inline JSON>'` so SessionStart and SessionEnd hooks
  fire into `limpid-hook`. Claude Code merges `--settings`
  additively, so the user's existing hooks and permissions stay
  intact.
- `limpid-hook` — receives hook payloads on stdin from Claude Code.
  Reads `LIMPID_PANE_ID` (= the owning split-leaf UUID, one per
  pane) and writes
  `{paneId, sessionId, cwd, updatedAt, lastHookEvent}` to
  `$LIMPID_SESSIONS_DIR/<pane_id>.json` so Limpid can replay the
  session on next launch.

## Environment contract

Set by Limpid before spawning the pty:

| Variable | Meaning |
|---|---|
| `PATH` | Original `PATH` with this directory prepended |
| `LIMPID_PANE_ID` | UUID of the owning split-tree leaf (one per pane) |
| `LIMPID_SESSIONS_DIR` | Directory to write session records into |
| `LIMPID_REAL_CLAUDE` | Optional override path to the real `claude` |
| `LIMPID_DISABLE_CLAUDE_RESUME` | `1` to bypass the shim entirely |

## Why shell scripts and not a Swift binary

- Zero startup cost compared to a Swift binary that would have to
  re-exec the real claude over a pipe.
- macOS code signing applies to Mach-O executables, not shell
  scripts, so notarization is unaffected.
- A reviewer can read the whole pipeline in one screenful.

## Failure policy

`limpid-hook` always exits `0`. A broken hook must never prevent the
user from running Claude. Diagnostic output goes to
`$TMPDIR/limpid-hook.log` on a best-effort basis.

The `claude` shim falls back to executing the real claude with no
overrides if `limpid-hook` is missing, if the real binary cannot be
located after PATH filtering, or if `LIMPID_DISABLE_CLAUDE_RESUME=1`
is set.
