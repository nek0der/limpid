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
  its own PID, and execs over itself.
- `limpid-hook` — the hook command Codex calls. A wrapper that reads
  `LIMPID_AGENT_HOOK_BACKEND` and execs either the Hook Helper's
  `hook codex` subcommand, which runs the Rust receiver in-process, or
  `limpid-hook.legacy`, the previous shell receiver kept for one release as
  the rollback path. The records both write are read back by
  the agent projection.
- `limpid-pretool-worktree-hook` — the second `PreToolUse` hook for the
  Bash tool. The same wrapper shape: `hook codex worktree` in the helper,
  or `limpid-pretool-worktree-hook.legacy`, which intercepts a `git
  worktree add` and re-runs it under the active Project's placement
  rules. Symmetric with the `claude-shim` file of the same name.

## Environment contract

Set by Limpid before spawning the pty. `CodexHookInstaller.environment()`
is the source of truth for the values.

| Variable | Meaning |
|---|---|
| `PATH` | Original `PATH` with this directory prepended |
| `LIMPID_PANE_ID` | UUID of the split-tree leaf the agent belongs to. For a hosted launch the shim replaces it with the id of the mirror tab's leaf before starting the agent, and carries the launching pane in the request instead |
| `LIMPID_AGENT_TMUX` | The tmux binary a hosted agent runs under. Set only when the user asked for hosting, the tmux found at launch is new enough for a mirror, and a watcher is reading the request directory |
| `LIMPID_AGENT_TMUX_SOCKET` | `tmux -L` name of this build's agent server |
| `LIMPID_AGENT_MIRROR_REQUESTS_DIR` | Where the shim writes the request that asks Limpid to open a tab on the session it just created (`AgentMirrorRequest`) |
| `LIMPID_AGENT_RUN_ID` | UUID of this Codex invocation; lifecycle-state filename key |
| `LIMPID_AGENT_TMUX_HOST_MODE` | Exported by the shim to the agent: `limpidHosted` when Limpid started it in a detached session of its own, `manual` inside the user's tmux |
| `LIMPID_AGENT_HOOK_BACKEND` | `rust` (default) runs hooks through the Hook Helper's Rust runtime; `shell` selects the previous receivers (`*.legacy`) for one release; set by `AgentHookBackend` |
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

The split between the shell shim and the Hook Helper's Rust receiver is
explained in `claude-shim/README.md` and applies here unchanged.

## Failure policy

`limpid-hook` always exits `0`. A broken hook must never stop the user
from running Codex. Set `LIMPID_HOOK_LOG=<path>` to capture its stderr.

The `codex` shim exits `127` with a diagnostic when it cannot find a
real `codex` to hand over to, since there is nothing left to fall back
on. With no `LIMPID_CODEX_HOOK_ARGS` set it hands the command line over
untouched, so a pane that Limpid never configured still runs Codex
normally.
