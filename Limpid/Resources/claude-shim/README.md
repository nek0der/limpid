# claude-shim

Small POSIX-shell scripts that let Limpid resume Claude Code sessions
across app restarts, badge agent state, and re-route
`git worktree add`, without ever writing to the user's
`~/.claude/settings.json`.

## Files

- `claude` — a transparent wrapper installed at
  `Limpid.app/Contents/Resources/claude-shim/claude`. Limpid prepends
  this directory to `PATH` for every pty it spawns, so when the user
  types `claude` inside a Limpid terminal this script runs first.
  It locates the real `claude` binary, then exec's it with
  `--settings '<inline JSON>'` so our hooks fire into `limpid-hook`.
  Claude Code takes the last `--settings` and ignores the rest, so
  when the user passes one of their own the shim merges the two
  first: their keys win, and the per-event hook arrays concatenate so
  both sets run.
- `limpid-hook` — receives hook payloads on stdin from Claude Code.
  Reads `LIMPID_PANE_ID` (= the owning split-leaf UUID, one per
  pane) and writes
  `{paneId, sessionId, cwd, updatedAt, lastHookEvent}` to
  `$LIMPID_SESSIONS_DIR/<pane_id>.json` so Limpid can replay the
  session on next launch. It also writes the agent-state and
  cwd-change records the sidebar badges read.
- `limpid-pretool-worktree-hook` — intercepts a `PreToolUse` Bash call
  that would create a git worktree and re-runs it under the active
  Project's placement rules.
- `settings.template.json` — the hook block the `claude` shim fills in
  and passes as `--settings`.
- `zdotdir/` — startup files that source the user's own first, then put
  the shim directories back at the front of `PATH`. Without this a
  user's `export PATH="/opt/homebrew/bin:$PATH"` buries the shim and
  no hook ever fires.

## Environment contract

Set by Limpid before spawning the pty:

| Variable | Meaning |
|---|---|
| `PATH` | Original `PATH` with this directory prepended |
| `ZDOTDIR` | Redirected to `zdotdir/` so the `PATH` edit survives the user's rc |
| `LIMPID_PANE_ID` | UUID of the launching split-tree leaf; not current ownership inside tmux |
| `LIMPID_AGENT_RUN_ID` | UUID of this Claude invocation; lifecycle-state filename key |
| `LIMPID_AGENT_TMUX_HOST_MODE` | `limpidHosted` for automatic hosting, `manual` inside user tmux |
| `LIMPID_SHIM_DIR` | This directory, so `zdotdir/.zshrc` can re-prepend it |
| `LIMPID_SESSIONS_DIR` | Directory to write session records into |
| `LIMPID_AGENT_STATES_DIR` | Directory to write agent-state records into |
| `LIMPID_CWD_EVENTS_DIR` | Directory to write cwd-change records into |
| `LIMPID_REAL_CLAUDE` | Optional override path to the real `claude` |
| `LIMPID_DISABLE_CLAUDE_RESUME` | `1` to bypass the shim entirely |

`PaneShellEnvironment` and `ClaudeShimLocator` are the source of truth
for the values.

Lifecycle records are keyed by `LIMPID_AGENT_RUN_ID`, not by the launching
pane. Inside tmux the receiver records the server socket, PID/start time, and
`TMUX_PANE` without contacting the server. Swift resolves current pane membership
and joins it to the tmux client's outer tty. This lets
a detached session move to another Limpid pane without moving or overwriting
the agent record.

Each shim entry mints a new run ID, including nested agent launches. Native
resume hints are written only outside tmux and include the owning run ID.
Records without enough tmux identity remain unresolved instead of attaching
to the inherited launch pane. Existing pre-upgrade runs may need a new hook
event before their attachment becomes visible. Manual tmux requires this shim
on the inner shell's PATH; no global agent hooks are installed.

## Why shell scripts and not a Swift binary

- Zero startup cost compared to a Swift binary that would have to
  re-exec the real claude over a pipe.
- macOS code signing applies to Mach-O executables, not shell
  scripts, so notarization is unaffected.
- A reviewer can read the whole pipeline in one screenful.

## Failure policy

`limpid-hook` always exits `0`. A broken hook must never stop the user
from running Claude. Set `LIMPID_HOOK_LOG=<path>` to capture its stderr.

The `claude` shim falls back to executing the real claude with no
overrides if `limpid-hook` is missing, if the real binary cannot be
located after PATH filtering, or if `LIMPID_DISABLE_CLAUDE_RESUME=1`
is set.
