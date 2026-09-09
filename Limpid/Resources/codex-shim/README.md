# codex-shim

Three POSIX-shell scripts that let Limpid track Codex CLI sessions,
badge agent state, and re-route `git worktree add`, without mirroring
the user's `~/.codex/` directory.

Codex resolves hooks from several sources and composes them, so the
flags this shim adds sit alongside the user's own configuration rather
than replacing it. The one thing a flag cannot carry is trust: Codex
refuses to run a hook whose hash it has not recorded, and it ignores a
trust entry supplied by the same flags that define the hook. So a single
marked block, and nothing else, is written into the user's
`~/.codex/config.toml`. `CodexUserConfig` owns that splice.

## Files

- `codex` — a transparent wrapper installed at
  `Limpid.app/Contents/Resources/codex-shim/codex`. Limpid prepends this
  directory to `PATH` for every pty it spawns, so a `codex` typed inside
  a Limpid terminal runs this first. It locates the real binary,
  splices in the `-c` overrides from `LIMPID_CODEX_HOOK_ARGS`, exports
  its own pid, and exec's over itself.
- `limpid-hook` — receives hook payloads on stdin and writes the
  per-pane session and agent-state records that `CodexSessionTracker`
  and `CodexAgentStateTracker` read back.
- `limpid-pretool-worktree-hook` — intercepts a `PreToolUse` Bash call
  that would create a git worktree and re-runs it under the active
  Project's placement rules. Symmetric with the `claude-shim` file of
  the same name.

## Environment contract

Set by Limpid before spawning the pty. `CodexHookInstaller.environment()`
is the source of truth for the values.

| Variable | Meaning |
|---|---|
| `PATH` | Original `PATH` with this directory prepended |
| `LIMPID_PANE_ID` | UUID of the launching split-tree leaf; not current ownership inside tmux |
| `LIMPID_AGENT_RUN_ID` | UUID of this Codex invocation; lifecycle-state filename key |
| `LIMPID_AGENT_TMUX_HOST_MODE` | `limpidHosted` for automatic hosting, `manual` inside user tmux |
| `LIMPID_CODEX_HOOK_ARGS` | Newline-separated arguments the `codex` shim splices in |
| `LIMPID_CODEX_SESSIONS_DIR` | Directory to write session records into |
| `LIMPID_CODEX_AGENT_STATES_DIR` | Directory to write agent-state records into |
| `LIMPID_CODEX_PID` | Exported by the `codex` shim; the pid the receiver records |
| `LIMPID_REAL_CODEX` | Optional override path to the real `codex` |

`LIMPID_CODEX_HOOK_ARGS` is newline-separated because each `-c` value is
TOML carrying spaces and quotes, which the default `IFS` would tear
apart.

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

The reasoning for shell scripts over a Swift binary is in
`claude-shim/README.md` and applies here unchanged.

## Failure policy

`limpid-hook` always exits `0`. A broken hook must never stop the user
from running Codex. Set `LIMPID_HOOK_LOG=<path>` to capture its stderr.

The `codex` shim exits `127` with a diagnostic when it cannot find a
real `codex` to hand over to, since there is nothing left to fall back
on. With no `LIMPID_CODEX_HOOK_ARGS` set it hands the command line over
untouched, so a pane that Limpid never configured still runs Codex
normally.
