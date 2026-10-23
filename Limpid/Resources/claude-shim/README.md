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
  when the user passes one of their own, the shim merges the two
  first: their keys win, and the per-event hook arrays concatenate so
  both sets run.
- `limpid-hook` — the hook command Claude Code calls. It is a wrapper that
  execs the Hook Helper's `hook claude` subcommand, which runs the Rust
  receiver in-process. The receiver reads `LIMPID_PANE_ID` (the UUID of the
  launching split-tree leaf, one per pane). It writes the resume hint under
  `$LIMPID_SESSIONS_DIR`, so Limpid can replay the session on the next
  launch. It also writes the run record the sidebar badges read, the turn
  records the changes panel reads, and the cwd-change events. Without the
  helper, the wrapper prints why on stderr, logs it, and exits 1. Claude
  Code shows that and carries on, and nothing else records the run.
- `limpid-pretool-worktree-hook` — the same wrapper shape as `limpid-hook`
  (`hook claude worktree` in the helper). It intercepts a `PreToolUse` Bash
  call that would create a git worktree and re-runs it under the active
  Project's placement rules.
- `settings.template.json` — the hook block the `claude` shim fills in and
  passes as `--settings`. Not in this directory in the source tree: it
  belongs to the provider crate that owns its shape, and the build copies it
  in beside the shim.
- `zdotdir/` — zsh startup files that source the user's own first, then
  put the shim directories back at the front of `PATH`. Without them, a
  user's `export PATH="/opt/homebrew/bin:$PATH"` buries the shim and
  no hook ever fires.

## Environment contract

Set by Limpid before spawning the pty, except the rows that say the shim
sets them:

| Variable | Meaning |
|---|---|
| `PATH` | Original `PATH` with this directory prepended |
| `ZDOTDIR` | Redirected to `zdotdir/` so the `PATH` edit survives the user's rc |
| `LIMPID_PANE_ID` | UUID of the launching split-tree leaf; not current ownership inside tmux |
| `LIMPID_AGENT_RUN_ID` | Minted by the shim: UUID of this Claude invocation; lifecycle-state filename key |
| `LIMPID_AGENT_TMUX_HOST_MODE` | Set by the shim: `limpidHosted` for automatic hosting, `manual` inside the user's own tmux |
| `LIMPID_SHIM_DIR` | This directory, so `zdotdir/.zshrc` can re-prepend it |
| `LIMPID_CLAUDE_HOOK_NAMESPACE` | Bundle identity used to keep the no-space hook link separate between Dev and Release builds |
| `LIMPID_SESSIONS_DIR` | Directory to write session records into |
| `LIMPID_AGENT_STATES_DIR` | Directory to write agent-state records into |
| `LIMPID_CWD_EVENTS_DIR` | Directory to write cwd-change records into |
| `LIMPID_REAL_CLAUDE` | Optional override path to the real `claude`, taken before any search (a test's stub) |
| `LIMPID_FOUND_CLAUDE` | The `claude` the new worktree sheet found, from the login shell's `PATH`, the known locations, or the last `PATH` a pane of the same project had, in that order (`AgentCatalog.detectInstallations`). Given only to the shell of the pane that the sheet's launch starts (`WorkspaceSession.StagedLaunch`), never to a restored one. The shim takes it when that pane's own `PATH` has no `claude`, before the known locations, while it still names an executable file, and removes it from what it hands on, so the agent and a tmux server never carry it. The pane's shell keeps it until the pane closes, as the same fallback for a later `claude` typed there |
| `LIMPID_CLAUDE_KNOWN_LOCATIONS` | Newline-separated places to look when the `PATH` has no `claude`, in order; one may hold a `*`. The agent catalog's list (`AgentCatalog.knownLocationsEnvironment`), so what the new worktree sheet offers is what the shim finds. A `*` folder is tried newest version first. The folder of an agent found off the `PATH`, here or through `LIMPID_FOUND_CLAUDE`, goes at the end of `PATH`; when it is a `#!/usr/bin/env node` script with a `node` beside it (an npm install under nvm), the shim starts it on that `node` rather than the first on `PATH` (`limpid_find_known_agent` and `limpid_node_beside` in `agent-shim/runtime-common.sh`) |
| `LIMPID_DISABLE_CLAUDE_RESUME` | `1` to run the real `claude` with no `--settings` override, so no hook fires |
| `LIMPID_INITIAL_PROMPT_FILE` | A new session's first instruction: a 0600 file the first launch that starts a session takes, deletes, and passes after `--` (see below); unset for no instruction |

`PaneShellEnvironment` and `ClaudeShimLocator` are the source of truth
for the values Limpid sets. The exceptions are `LIMPID_INITIAL_PROMPT_FILE`
and `LIMPID_FOUND_CLAUDE`, which only a pane with a staged launch gets
(`PaneHostRepresentable.launch`).

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
the launch starts no new session (`-p`, `-r`, `--continue`, a
subcommand, …), and puts `sh -c "$limpid_prompt_reader"` in front of the
agent: the reader reads the file, deletes it, and execs
`claude … -- "<instruction>"`. Claude takes a lone word after `--` as a
subcommand of that name, so a one-word instruction gets a trailing space.
Inside tmux the same reader runs as the session's command, so the
instruction stays off tmux's command line, which tmux limits to about
16 KB. A later launch in the pane finds no file.

## Why the shim is a shell script and the hook receiver is not

- The `claude` shim prepares the environment and hook settings, then replaces
  itself with the real CLI. Keeping this launch setup in a script avoids
  adding another compiled launcher to the bundle.
- The hook receiver moved into the signed Hook Helper: `limpid-hook` is a
  wrapper that execs `AgentIntegrationHookHelper hook claude`, which runs
  the Rust hook runtime in-process.
- macOS code signing applies to Mach-O executables, not shell scripts,
  so the wrappers do not affect notarization.

## Failure policy

`limpid-hook` exits `0` on any failure the helper runs into, because a
broken hook must never stop the user from running Claude. The one exception
is a missing helper, which exits `1` (see [Files](#files) above); Claude shows
that and carries on. Apart from that, only a successful intercept by
`limpid-pretool-worktree-hook` exits non-zero. Set `LIMPID_HOOK_LOG=<path>`
to capture the helper's diagnostics.

The `claude` shim falls back to executing the real `claude` with no
overrides if `limpid-hook` or the bundled `settings.template.json` is
missing, or if `LIMPID_DISABLE_CLAUDE_RESUME=1` is set. When it cannot find
a real `claude` at all, it exits `127` with a diagnostic.
