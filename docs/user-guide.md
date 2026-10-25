# Limpid user guide

The README gives a short tour. This guide covers each part of the window in
detail, then the workflow, the other features, and every default shortcut.

## Terms

- **Turn.** One round of an agent's work: from the prompt you send until the
  agent stops and waits for you again. Limpid snapshots the worktree at the
  start and end of each turn.
- **Viewed line.** How far you have reviewed a conversation. Turns before
  the line are viewed; turns after it are unviewed, and stay in Needs
  Attention until you move the line past them.
- **Hunk.** One block of changed lines in a diff, with the unchanged lines
  around it.
- **Scope.** What a review shows: one conversation's unviewed turns, all
  unviewed turns in the worktree, a single turn, the uncommitted changes, or
  the branch against its base.

## The window

Each window shows one project at a time. Reading the screenshot left to
right:

### Title bar

The project and worktree menus, back and forward, the command palette field
(⇧⌘P), and **Needs Attention** with its count.

### Left rail

**Worktrees** (shows or hides the sidebar), **All Projects**, and
**Notification History**; below them,
updates (when one is available), keyboard shortcuts, and **Settings**.

### Sidebar

- Every project sits under its own header, in the order you give them (drag
  a header, or ⌥⌘↑ ⌥⌘↓ while the sidebar has focus). Under a header are its
  worktrees, one per row, with the project's own folder after them and the folded lists below.
- A row shows the state (running, waiting for approval, stopped, unread), the
  name, the time, one fact such as "Unread · 4 files changed" or "PR #324 · Open", and
  a badge for each agent.
- A row you renamed starts its second line with the worktree's folder, as in
  "login-redesign · 3 Uncommitted", so it still says which worktree it is. A
  fact that only repeats the state, such as "Idle", gives way to the folder
  alone. A name that already matches the folder, in full or without the
  project's folder name in front, shows no folder. The worktree menu,
  **Needs Attention**, and **All Projects** show the same folder beside the
  name.
- Worktrees whose PR is merged or closed, with nothing open and nothing uncommitted, fold into **Ready to Clean Up**, and
  the ones Git reports that you never opened (an agent's own, for one) into
  **Other Worktrees**.
- Fold a header and it shows what waits inside.
- A header's **+** opens **New Worktree** for that project (⌘N for the
  window's).
- The **Scratch** row at the bottom holds terminals that belong to no
  project.

### Session area

The worktree's header with its commits and uncommitted files, the pane strip
of tabs (agents, shells, the review), and the terminal.

The **▾** at the strip's left end (⇧⌘A) opens **Open Tabs**: every tab of the
session, with who runs in it and its state, to search, switch to, or close.
Use it when the strip has more tabs than fit.

### Decision bar

Under each agent pane. One line sums up the unviewed turns (their numbers,
files, lines, and checks) or says what the agent is waiting on. It offers only the
actions the CLI does not have:

- **Mark as Viewed** (⌘⏎)
- **Review Unviewed**
- **Resume Same Conversation**, after a stop
- a **⋯** menu with **Restore Code to Before T*n*…** (and, after a stop,
  **Show Partial Changes** and **Start New Conversation**)

Approvals and questions are answered in the agent's own prompt, not here.

### Changes panel

⌥⌘I, off by default. Every conversation's turns in the worktree as one
timeline, with the unviewed count and range and a **Conversation** filter.

- Each turn offers **Mark as Viewed up to Here** and **Restore Code to Before
  This Turn…**.
- **Review All Unviewed** opens the review.
- **Commit & PR** at the bottom shows what is not yet in the base branch or
  not yet pushed, and offers **Create PR** (with `gh`) and **Clean Up
  Worktree…**.

### Status band

Where you are, the agent, the folder, the terminal size, and the
encoding.

## The workflow

1. **Start.** **New Worktree** (⌘N) makes a worktree on a new or existing
   branch, fetching a remote base first and copying in the ignored files the
   project names, such as `.env`, then opens Claude Code, Codex, a shell, or
   nothing in it. The sheet only makes the worktree; you give the agent its
   first instruction in its own prompt. **Create** (⌘⏎) makes it; ⌥⌘N makes
   one at once with the last choices, without the sheet.
2. **It works.** The sidebar row and the decision bar show what the agent is
   doing. Nothing moves or takes focus on its own.
3. **It needs you.** An approval, a question, a stop, or a finished turn
   joins **Needs Attention**. Press ⌘J to go to the next item (⇧⌘J for the
   previous one), or ⌃⌘J to open the list. A request from a pane you are
   looking at goes to the agent's own prompt. A request from a pane out of
   sight waits on the window's approval card, where you can answer it without
   switching panes. While another app is in front, every request waits, and
   the menu bar can answer one that is a short, low-impact shell command. Codex questions are always answered in
   the terminal.
4. **You review.** **Review Unviewed**, **Review All Unviewed**, or ⌥⌘R opens
   a review tab in place of the terminal. Its scope menu picks one
   conversation's unviewed turns, all unviewed turns in the worktree, a
   single turn, uncommitted changes, or the branch against its base. Comment
   on lines, then insert the comments into the agent's input as one message.
   You press Return to send it. Comments survive a restart, and a comment
   whose code has moved since you wrote it is held back rather than sent. You
   can also discard a hunk, and undo the discard. ⌥⌘J reviews the focused
   agent's latest turn.
5. **You decide.** **Mark as Viewed** moves the viewed line past the turns
   you read, and they leave **Needs Attention**. **Restore Code to Before This
   Turn…** puts the working tree back to before a turn. It leaves the
   conversation, staged changes, and commits alone, and it can be undone.
   After a stop (an API error, a usage limit, an agent that exited), **Resume
   Same Conversation** picks up where the agent left off. A usage-limit stop
   can notify you when the limit resets.

## More

- **Native approvals.** Limpid's approval service holds Claude Code and Codex
  permission requests for the approval card. The release DMG has it. A build
  without a Team ID leaves every approval to the agent's own prompt; see
  [CONTRIBUTING.md](../CONTRIBUTING.md#native-approvals-in-a-debug-build).
- **Worktrees.** Create, switch, and delete worktrees from **New Worktree**,
  the worktree menu, and the sidebar row. When an agent `cd`s into another
  worktree, Limpid offers to move the tab there.
- **Pull request status.** A row with an open, draft, merged, or closed PR
  shows the PR's state, with its checks on the mark's corner: failing,
  running, or passed. Hover for the title and checks. Limpid uses whatever
  `gh` or `glab` is already signed in.
- **Session restore.** Projects, worktrees, tabs, splits, and windows come
  back after a relaunch, with each pane's scrollback, and agent panes resume
  their conversations.
- **Quick Terminal.** A system-wide hotkey drops a terminal over any app from
  a screen edge or the center. It is off until you set a hotkey in
  **Settings → Quick Terminal**.
- **All Projects and notifications.** **All Projects** (⌥⌘O) shows every
  project's worktrees with something open as cards, grouped by state (needs
  you, running, idle), with each terminal's last lines: the one view sorted
  by state, since the sidebar keeps your order. **Notification History**
  (⇧⌘N) keeps the notifications Limpid sent. The menu bar icon shows the
  attention state.
- **Updates and languages.** Limpid checks for updates once a day through
  Sparkle and installs one when you choose to. The interface is in English and Japanese; choose one in
  **Settings → General → Display Language**.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌘J / ⇧⌘J | Next / previous item that needs you |
| ⌃⌘J | Show Needs Attention |
| ⌘⏎ | Decision bar's main action (Mark as Viewed, Resume, Notify When It Resets) |
| ⌥⌘R | Review |
| ⌥⌘J | Review Latest Turn |
| ⌥⌘I | Changes panel |
| ⌘N | New Worktree |
| ⌘T | New Tab |
| ⌘W | Close (the pane, or the review or Settings in front) |
| ⌥⌘W | Close Tab |
| ⇧⌘W | Close Window (agents keep running) |
| ⌘] / ⌘[ | Next / previous worktree |
| ⇧⌘] / ⇧⌘[ | Next / previous tab |
| ⇧⌘A | Show Open Tabs |
| ⌃⌘1…⌃⌘9 | Go to worktree N |
| ⌘1…⌘9 | Go to tab N |
| ⌥⌘↑ / ⌥⌘↓ | Move the project up / down (while the sidebar has focus; the panes otherwise) |
| ⌥⌘O | All Projects |
| ⇧⌘N | Notification History |
| ⇧⌘P / ⌘P | Command Palette / Quick Open |
| ⌘, | Settings |
| ⌘/ | Keyboard Shortcuts |

You can change most bindings in **Settings → Keyboard**. Press ⌘/ to see the
full list with your own bindings.
