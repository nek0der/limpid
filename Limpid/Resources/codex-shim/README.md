# codex-shim

Three POSIX-shell scripts that let Limpid track Codex CLI sessions,
badge agent state, and re-route `git worktree add`, without mirroring
the user's `~/.codex/` directory.

Codex resolves hooks from several sources and composes them, so the
flags this shim adds sit alongside the user's own configuration rather
than replacing it. Codex refuses to run a hook whose hash it has not
recorded, and it reads that record from the flags as well as from the
user's own `config.toml`, so the trust travels in the same flags
(`CodexHookInjection`) and a Codex with any `CODEX_HOME` runs our hooks.
The record has to be one inline table, `hooks.state={…}`: Codex splits a
flag's key at each dot, and our keys hold one. Earlier builds wrote the
trust tables into `~/.codex/config.toml` instead; `CodexUserConfig` takes
them out again.

## Files

- `codex` — a transparent wrapper installed at
  `Limpid.app/Contents/Resources/codex-shim/codex`. Limpid prepends this
  directory to `PATH` for every pty it spawns, so a `codex` typed inside
  a Limpid terminal runs this first. It locates the real binary,
  splices in the `-c` overrides from `LIMPID_CODEX_HOOK_ARGS`, exports
  its own PID, and execs the real binary in its place.
- `limpid-hook` — the hook command Codex calls. It is a wrapper that execs
  the Hook Helper's `hook codex` subcommand, which runs the Rust receiver
  in-process. The agent projection reads back the records it writes.
  Without the helper, the wrapper prints why on stderr, logs it, and exits
  1, and nothing else records the run.
- `limpid-pretool-worktree-hook` — the second `PreToolUse` hook, after
  `limpid-hook`, matched to the Bash tool. It has the same wrapper shape
  (`hook codex worktree` in the helper). It intercepts a `git worktree add`
  and re-runs it under the active Project's placement rules, like the
  `claude-shim` file of the same name.

## Environment contract

Set by Limpid before spawning the pty, except the rows that say the shim
sets them. `PaneShellEnvironment`, `CodexShimLocator`, and
`CodexHookInstaller.environment(writesRecords:)` are the source of truth for
the values Limpid sets. The exceptions are `LIMPID_INITIAL_PROMPT_FILE` and
`LIMPID_FOUND_CODEX`, which only a pane with a staged launch gets
(`PaneHostRepresentable.launch`).

| Variable | Meaning |
|---|---|
| `PATH` | Original `PATH` with this directory prepended |
| `LIMPID_PANE_ID` | UUID of the launching split-tree leaf; not current ownership inside tmux |
| `LIMPID_AGENT_RUN_ID` | Minted by the shim: UUID of this Codex invocation; lifecycle-state filename key |
| `LIMPID_AGENT_TMUX_HOST_MODE` | Set by the shim: `limpidHosted` for automatic hosting, `manual` inside the user's own tmux |
| `LIMPID_CODEX_SHIM_DIR` | This directory, so `claude-shim/zdotdir/.zshrc` can re-prepend it |
| `LIMPID_CODEX_HOOK_ARGS` | Newline-separated arguments the `codex` shim splices in |
| `LIMPID_CODEX_SESSIONS_DIR` | Directory to write session records into |
| `LIMPID_CODEX_AGENT_STATES_DIR` | Directory to write agent-state records into |
| `LIMPID_CODEX_PID` | Set by the shim: its own PID, which the receiver records |
| `LIMPID_REAL_CODEX` | Optional override path to the real `codex`, taken before any search (a test's stub) |
| `LIMPID_FOUND_CODEX` | The `codex` the new worktree sheet found, from the login shell's `PATH`, the known locations, or the last `PATH` a pane of the same project had, in that order (`AgentCatalog.detectInstallations`). Given only to the shell of the pane that the sheet's launch starts (`WorkspaceSession.StagedLaunch`), never to a restored one. The shim takes it when that pane's own `PATH` has no `codex`, before the known locations, while it still names an executable file, and removes it from what it hands on, so the agent and a tmux server never carry it. The pane's shell keeps it until the pane closes, as the same fallback for a later `codex` typed there |
| `LIMPID_CODEX_KNOWN_LOCATIONS` | Newline-separated places to look when the `PATH` has no `codex`, in order; one may hold a `*`. The agent catalog's list, set by `PaneShellEnvironment` from `AgentCatalog.knownLocationsEnvironment`, so what the new worktree sheet offers is what the shim finds. A `*` folder is tried newest version first. The folder of an agent found off the `PATH`, here or through `LIMPID_FOUND_CODEX`, goes at the end of `PATH`; when it is a `#!/usr/bin/env node` script with a `node` beside it (an npm install under nvm), the shim starts it on that `node` rather than the first on `PATH` (`limpid_find_known_agent` and `limpid_node_beside` in `agent-shim/runtime-common.sh`) |
| `LIMPID_INITIAL_PROMPT_FILE` | A new session's first instruction: a 0600 file the first launch that starts a session takes, deletes, and passes after `--` (see below); unset for no instruction |

`LIMPID_CODEX_HOOK_ARGS` is newline-separated because each `-c` value is
TOML that carries spaces and quotes, which the default `IFS` would split
apart.

Lifecycle records are keyed by `LIMPID_AGENT_RUN_ID`, not by the launching
pane. Inside tmux the receiver records the server socket, the server's PID and
start time, and `TMUX_PANE`, without contacting the server. Swift resolves
current pane membership and joins it to the tmux client's outer tty. This lets
a detached session move to another Limpid pane without moving or overwriting
the agent record.

Each shim entry mints a new run ID, including nested agent launches. Native
resume hints are written only outside tmux and include the owning run ID.
Records without enough tmux identity remain unresolved instead of attaching
to the inherited launch pane. Existing pre-upgrade runs may need a new hook
event before their attachment becomes visible. Manual tmux requires this shim
on the inner shell's `PATH`, because no global agent hooks are installed.

The split between the shell shim and the Hook Helper's Rust receiver is
explained in [`claude-shim/README.md`](../claude-shim/README.md) and applies
here unchanged.

## First instruction

Limpid no longer writes these files: an earlier build's new worktree sheet
took a first instruction, and this one still delivers the file a restored
tab staged, for one release (`InitialPromptFile`).

A first instruction is never put in an environment a later process
inherits, in a shell's program text, or in tmux's command string. That
build wrote it to a 0600 file, and the pane is still handed it in
`LIMPID_INITIAL_PROMPT_FILE`; a small reader script passes the text to
the agent as its one last argument. The shim's `exec_agent` takes it
(`limpid_take_initial_prompt` in `agent-shim/runtime-common.sh`) unless
the launch starts no new session (`resume`, `fork`, `exec`, `--version`,
…), and puts `sh -c "$limpid_prompt_reader"` in front of the agent: the
reader reads the file, deletes it, and execs `codex … -- "<instruction>"`.
Inside tmux the same reader runs as the session's command, so the
instruction stays off tmux's command line, which tmux limits to about
16 KB. A later launch in the pane finds no file.

## Failure policy

`limpid-hook` exits `0` on any failure the helper runs into, because a
broken hook must never stop the user from running Codex. The one exception
is a missing helper, which exits `1` (see [Files](#files) above). Apart from
that, only a successful intercept by `limpid-pretool-worktree-hook` exits
non-zero. Set `LIMPID_HOOK_LOG=<path>` to capture the helper's diagnostics.

The `codex` shim exits `127` with a diagnostic when it cannot find a
real `codex` to hand over to, since there is nothing left to fall back
on. With no `LIMPID_CODEX_HOOK_ARGS` set, it hands the command line over
untouched, so a pane that Limpid never configured still runs Codex
normally.
