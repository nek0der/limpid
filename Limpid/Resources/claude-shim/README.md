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
  It locates the real `claude` binary, then execs it with
  `--settings '<inline JSON>'` so our hooks fire into `limpid-hook`.
  Claude Code takes the last `--settings` and ignores the rest, so
  when the user passes one of their own the shim merges the two
  first: their keys win, and the per-event hook arrays concatenate so
  both sets run.
- `limpid-hook` — the hook command Claude Code calls. A wrapper that reads
  `LIMPID_AGENT_HOOK_BACKEND` and execs either the Hook Helper's
  `hook claude` subcommand, which runs the Rust receiver in-process, or
  `limpid-hook.legacy`, the previous shell receiver kept for one release as
  the rollback path. The legacy receiver reads `LIMPID_PANE_ID` (= the owning
  split-leaf UUID, one per pane) and writes
  `{paneId, sessionId, cwd, updatedAt, lastHookEvent}` to
  `$LIMPID_SESSIONS_DIR/<pane_id>.json` so Limpid can replay the
  session on next launch. It also writes the agent-state and
  cwd-change records the sidebar badges read.
- `limpid-pretool-worktree-hook` — the same wrapper shape as `limpid-hook`
  (`hook claude worktree` in the helper, or the `.legacy` receiver). The
  legacy receiver intercepts a `PreToolUse` Bash call
  that would create a git worktree and re-runs it under the active
  Project's placement rules.
- `settings.template.json` — the hook block the `claude` shim fills in and
  passes as `--settings`. Not in this directory in the source tree: it
  belongs to the provider crate that owns its shape, and the build copies it
  in beside the shim.
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
| `LIMPID_PANE_ID` | UUID of the split-tree leaf the agent belongs to. For a hosted launch the shim replaces it with the id of the mirror tab's leaf before starting the agent, and carries the launching pane in the request instead |
| `LIMPID_AGENT_TMUX` | The tmux binary a hosted agent runs under. Set only when the user asked for hosting, the tmux found at launch is new enough for a mirror, and a watcher is reading the request directory |
| `LIMPID_AGENT_TMUX_SOCKET` | `tmux -L` name of this build's agent server |
| `LIMPID_AGENT_MIRROR_REQUESTS_DIR` | Where the shim writes the request that asks Limpid to open a tab on the session it just created (`AgentMirrorRequest`) |
| `LIMPID_AGENT_RUN_ID` | UUID of this Claude invocation; lifecycle-state filename key |
| `LIMPID_AGENT_TMUX_HOST_MODE` | Exported by the shim to the agent: `limpidHosted` when Limpid started it in a detached session of its own, `manual` inside the user's tmux |
| `LIMPID_SHIM_DIR` | This directory, so `zdotdir/.zshrc` can re-prepend it |
| `LIMPID_CLAUDE_HOOK_NAMESPACE` | Bundle identity used to keep the no-space hook link separate between Dev and Release builds |
| `LIMPID_AGENT_HOOK_BACKEND` | `rust` (default) runs hooks through the Hook Helper's Rust runtime; `shell` selects the previous receivers (`*.legacy`) for one release; set by `AgentHookBackend` |
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

Each shim entry mints a new run ID, including nested agent launches. Resume
hints include the owning run ID and are written for every run whose pane owns
its session: one outside tmux, and one Limpid hosts in tmux. A hosted run's
hint goes in the `tmux-hosted` subdirectory of the session directory, where a
build from before mirror tabs does not look for it — such a build shows a
converted tab as a plain shell, and a hint it could read would have it resume
the conversation the agent is still having in tmux. A run inside the user's
own tmux writes no hint: there `LIMPID_PANE_ID` names the pane showing a
client, not the pane that owns the session.
Records without enough tmux identity remain unresolved instead of attaching
to the inherited launch pane. Existing pre-upgrade runs may need a new hook
event before their attachment becomes visible. Manual tmux requires this shim
on the inner shell's PATH; no global agent hooks are installed.

## Why the shim is a shell script and the hook receiver is not

- The `claude` shim prepares the environment and hook settings, then replaces
  itself with the real CLI. Keeping this launch setup in a script avoids
  adding another compiled launcher to the bundle.
- The hook receiver moved into the signed Hook Helper: `limpid-hook` is a
  wrapper that execs `AgentIntegrationHookHelper hook claude`, which runs
  the Rust hook runtime in-process. The shell receiver is kept as
  `limpid-hook.legacy` for one release and is selected with
  `LIMPID_AGENT_HOOK_BACKEND=shell`.
- macOS code signing applies to Mach-O executables, not shell scripts,
  so the wrappers do not affect notarization.

## Failure policy

`limpid-hook` always exits `0`. A broken hook must never stop the user
from running Claude. Set `LIMPID_HOOK_LOG=<path>` to capture its stderr.

The `claude` shim falls back to executing the real claude with no
overrides if `limpid-hook` is missing, if the real binary cannot be
located after PATH filtering, or if `LIMPID_DISABLE_CLAUDE_RESUME=1`
is set.
