# Known limitations

Each Limpid window shows one project at a time: a sidebar of worktrees, the
terminal, and the Changes panel. This page lists what Limpid does not do
yet, what it does on purpose that may surprise you, and what has not been
checked on a real machine. It describes the current build. Entries go away
as they are fixed or confirmed.

## Accessibility

- **VoiceOver cannot read the terminal.** A terminal pane is announced as
  "Terminal", but its text and cursor are not exposed. What an agent changed
  can be read in the review tab and the Changes panel; what it printed
  cannot.
- **A hunk header's Comment and Discard buttons cannot be reached with the
  review's keys.** From the keyboard, `]` moves to the next hunk, ⇧J
  extends the selection over its lines, and `c` comments on them.
  Discarding a hunk needs the pointer.

## Approvals and questions

- **Native approvals need a signed build.** The approval service starts only
  in a build signed with a Team ID. An ad-hoc signed Debug build (the default
  for `make build`) leaves every approval to the agent's own terminal prompt.
  `CONTRIBUTING.md` explains how to sign a development build.
- **The approval card holds only requests whose pane you cannot see.** A
  request from a pane you are looking at while Limpid is in front goes
  straight to the agent's own prompt there. The card holds a request whose
  pane is out of sight, or whose pane the review tab is covering. When
  Limpid is not in front, the menu bar can answer a short shell command that
  is not high-impact; any other request opens Limpid.
  While VoiceOver is running, a held request is not handed to the terminal
  on its own when its pane comes into sight. Answer it on the card, or
  choose "Answer in terminal".
- **Codex questions are answered in the terminal.** While Codex waits on a
  question, Limpid shows "Needs answer" with the first question's words, but
  no Codex hook can answer it, so there is no card. A question Codex asks
  without stopping, as it does in its default mode, shows as work in
  progress: the turn goes on, and the question is answered in Codex's own
  prompt.
- **An approval refused in Claude Code's own dialog can stay listed for a
  while inside tmux.** Claude Code sends no hook when you choose "No" in the
  terminal. Limpid reads the answer from the status Claude Code reports to
  the terminal (OSC 7501), which it does not report inside tmux or with
  `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` set. There the row keeps saying
  "Needs approval" until the next prompt in that pane or the end of the
  turn.
- **No time left is shown after an approval goes to the terminal.** Once a
  request is handed to the agent's own prompt, the agent decides how long it
  waits, and Limpid cannot read that time.
- **"Always allow" is the agent's own choice.** Limpid adds no such option and
  writes nothing to an agent's settings. Use the agent's prompt in the
  terminal.

## Notifications

- **Limpid cannot tell whether a Focus is on**, so the notification history
  never warns that a Focus may hold banners back. Reading it needs an
  entitlement and a permission prompt that Limpid does not ask for.
- **A reset notification you asked for is not kept across a restart.** After
  a restart, a usage-limit stop offers "Notify When It Resets" again.
- An open All Projects card or Needs Attention list can keep saying that a
  limit "resets" at a time that has already passed, until you close and
  reopen it.

## Turn history and restore

- **Restore and Discard do not lock out other programs.** Limpid checks the
  files before and after, and stops if an agent or an editor changed them.
  Another program can still write in between.
- **A pane with turn snapshots turned off** (`LIMPID_TURN_SNAPSHOT=0` in its
  environment, which stops Limpid from recording what each turn changed)
  takes no lock, so its agent can start a turn while another pane of the
  same worktree restores one.
- **A stalled snapshot can hold a Claude Code or Codex prompt for up to 10
  minutes**, the timeout of the hooks that take it at a turn's start
  (`UserPromptSubmit`) and end (`Stop`). The snapshot has no shorter limit
  of its own.
- **A turn that goes on after a failed stop** is recorded as a failed turn
  with only its end, and the turn before keeps the first end.
- **A turn record larger than 4 MiB is not read.** The turn keeps what
  Limpid read of it before, or is not listed if Limpid read nothing.
  Nothing on screen says so; Limpid logs it once (`agent.turn-records`).
- **A turn's tokens are read when it ends**, so a running turn shows none.
  Claude Code's tokens are read from the last 4 MiB of its transcript; a
  turn that began before that, or whose last response was still not
  written a second after the turn ended, shows its count with "≥". A
  subagent still running when the turn ended counts only what it had used
  by then.
- **A Claude turn stopped inside tmux can keep showing as running.**
  Claude sends no hook when you stop its work with Esc or Ctrl+C. Limpid
  reads the stop from the status Claude Code reports to the terminal (OSC
  7501), which it does not report inside tmux or with
  `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` set. There the turn shows as running
  until your next prompt in that pane, or until Claude's idle notification
  if one comes a minute later, and a turn your next prompt ends shows no
  tokens.
- **A Codex turn is read when it ends.** Its checks are read from its
  rollout at that moment, so they appear together rather than as each one
  finishes. A Codex turn interrupted before its first response arrives
  shows no tokens, since Codex records none for it. A very long Codex turn
  may count fewer test runs than it ran: its card says so with "…" and its
  tooltip with "at least", while the decision bar's count of failures is
  the one Limpid read.
- **A Codex turn can leave some subagents' tokens out.** Codex keeps each
  subagent's work in a rollout of its own, which Limpid finds by the
  thread the turn's rollout names it by. A subagent's own subagents are
  named only in its rollout, which Limpid does not search, so their tokens
  are not counted. Nor are those of a subagent that only the start of a
  very long turn named, when Limpid reads only the end of that turn's
  rollout.
- **A Claude subagent named again in a later turn is counted again**:
  Limpid reads the subagent's whole transcript at each turn that names it.
- **A turn record written by an older Limpid and a newer one in turn** can
  show a test count that leaves out the runs the older one recorded.
- **A turn keeps its last 16 test runs** one by one; the card shows the last
  three, and the tooltip counts all of them.
- **"Create PR" needs `gh`**, so Limpid does not create a GitLab merge
  request.

## New worktrees

- **The new worktree sheet takes no first prompt.** A tab that an earlier
  build opened in the background with one, and that has not been shown
  since, still hands the prompt to its agent the first time it is shown. If
  you close that tab before then, the prompt is dropped with it.
- **Making a worktree from a pull request needs `gh` or `glab`**, installed
  and signed in to the project's remote. The head is fetched from the
  forge's own ref for the request, so a fork needs no remote of its own,
  but GitLab may stop keeping that ref for a merge request closed long ago.
  A local branch with the request's branch name is used only when it is
  already at the request's commit; otherwise the worktree gets `pr/<number>`.
- **Carrying uncommitted changes into a new worktree** stops before anything
  is made when the worktree they are in has a merge, rebase, cherry-pick, or
  revert under way, has conflicts to resolve, uses a sparse checkout or a
  split index, has files marked skip-worktree or assume-unchanged or added
  with `git add -N`, changes a submodule or a repository inside it, or has
  a folder with ignored files where a tracked file was, and when the
  changes conflict with the new worktree's starting point. It needs Git
  2.40 or later. If a file would come out of the new worktree with other
  bytes than it has (a line-ending setting or a filter), nothing is moved. Empty folders do not come along, nor do files Git ignores
  (those come only through the copy that Project Settings names), and
  changes inside a submodule stay where they are.
- **A worktree that changes while its changes are carried keeps them.** If
  an agent or an editor writes in it, or Git holds its index, in the moment
  the changes are moved, they end up in both worktrees, and the bar under
  the new one says so; nothing is taken out of the first one. A write in
  the instant Git puts the first worktree's files back can still be lost,
  as it can in any `git checkout`. A `git commit` still waiting on its
  message editor in that worktree is not seen: once it finishes, its commit
  shows as undone by staged changes, which `git restore --staged --worktree
  .` puts right. If Limpid quits while it holds that
  worktree's index, Git stops on the `index.lock` left behind until it is
  removed.

## Codex

- **A failed Codex turn shows as failed up to ten seconds late.** Codex runs
  no hook when a turn fails (an error from the server, a model it does not
  have, the plan's usage limit), so Limpid reads the failure from the
  session's rollout, which it checks every ten seconds.
- **A moved Codex home (`CODEX_HOME`) gets no Limpid hooks.** Codex runs a
  hook only when its own `config.toml` records that the hook is trusted, and
  Limpid writes that record only into `~/.codex/config.toml`. A Codex
  started with `CODEX_HOME` set elsewhere (in `.zshrc`, or a project's
  `.envrc`) reads another `config.toml`. It treats Limpid's hooks as not
  reviewed and does not run them, so its turns, approvals, and stops do not
  reach Limpid. Limpid does not read the variable itself: the pane's shell
  sets it after Limpid starts, and it can differ from pane to pane.
- **A resume inside your own tmux is judged by what tmux says.** If your
  shell starts tmux at its prompt, or the pane was inside tmux when Limpid
  quit, the resume Limpid types runs inside that tmux. Codex reports nothing
  until its first prompt, so at the 45-second deadline Limpid asks your tmux
  server what is running in the pane its client shows. If the server does
  not answer within half a second, or Limpid has not yet matched the client
  to the pane, Limpid treats the resume as successful. A resume that failed
  there then lists no stop, and only the terminal shows why.

## For contributors: not yet confirmed on a real machine

These need a signed approval service, sleep, or physical input that the
automated checks cannot provide. They still have to be checked by hand:

- that Claude Code and Codex draw no prompt of their own while Limpid holds
  an approval, and draw it at once when the pane is opened;
- the warning shown when the held approvals near their limit of 128;
- the time left after the Mac sleeps and wakes;
- whether locking the screen or switching users stops a pane from counting as
  seen;
- which pane counts as seen with splits, zoom, and tmux;
- a hidden full-screen window's Space, Stage Manager, several displays, and
  ⌥⌘W;
- that an ad-hoc signed Debug build leaves every approval to the agent's own
  prompt, as described above;
- a full pass through the window by keyboard alone with VoiceOver.
