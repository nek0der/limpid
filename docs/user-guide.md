# Weir user guide

The README gives a short tour. This guide covers each part of the window in
detail, then the workflow, the other features, and every default shortcut.

## Terms

- **Turn.** One round of an agent's work: from the prompt you send until the
  agent stops and waits for you again. Weir snapshots the worktree at the
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
updates (when one is available), **Plan Usage**, keyboard shortcuts, and
**Settings**.

**Plan Usage** opens a panel beside the rail that shows how much of each
agent's plan limits your account has used: each limit window the agent
reports (the 5-hour and weekly ones, as a rule), and when each resets. A dot
on the icon says a window is at 80% or more; a larger red one says a window
is used up. A click outside the panel or Escape closes it.

- **Claude Code** reports its usage to its status line, so Weir reads it
  there: the values are the ones from the last reply of a Claude Code
  session in a Weir pane, and the panel says how old they are. Weir runs
  your own status line in its place with the same input, so what you see
  does not change. Without a status line of your own (`/statusline` sets one
  up), Weir leaves the slot empty and has nothing to show.
- **Codex** is asked for its usage once when Weir starts, and every
  minute while the panel is open. It answers when you are signed in to Codex
  with ChatGPT. When your account has limit resets to spend, the panel says
  how many are left and when the first one lapses.

### Sidebar

- Every project sits under its own header, in the order you give them (drag
  a header, or ⌥⌘↑ ⌥⌘↓ while the sidebar has focus). Under a header comes
  the project's own folder first, marked with a house after its name, then its
  worktrees, one per row, and the folded lists below. The repository's row
  always stays first; worktrees move only among themselves. While the list
  scrolls, a project's header stays at the top until the next project's reaches
  it.
- Drag a tab, or a pane by its header or with ⌥⌘, onto any row of any project
  to move it there; the window stays where it is. Dropped on a project's
  header it lands on the repository's row. Rest it on a folded header and the
  project opens for the drag. A missing worktree's row takes neither. The
  tab's running panes stay in their folders; its new panes start in the row's.
  Drop a pane on a tab in the pane strip and it joins that tab.
- A row shows the state (running, waiting for approval, stopped, unread, or
  working in the background after a turn: the finished or unread ring with a
  dot circling it), the name, the time since an agent last moved ("now",
  "12m", "3h", "2d"), one fact such as "Unread · 4 files changed" or
  "PR #324 · Open", and a badge for each kind of agent. With two kinds in the
  row, the fact names the agent it is about ("Codex · Needs approval").
- A pane strip tab has the same badges, each with its own agent's state. Past
  three kinds, the first two stay and "+2" stands for the rest; the tab's
  tooltip and its **Open Tabs** row name them all. Until the conversation it
  follows has a name, a tab of several agents goes by its folder.
- Each pane's header starts with its agent's badge. While a pane is zoomed,
  its header says how many panes the zoom hides and what most needs you among
  them; click it to go there.
- At rest, the fact is the folder's Git state: "3 files uncommitted" first,
  else the PR, else "+2 commits" (commits the default branch does not have),
  else "No changes". The PR's mark stays at the right while the line says
  what is uncommitted, and the tooltip names the commits ahead whatever the
  line shows.
- A row goes by its branch, such as `main` or `feat/login`. A row with no
  branch, such as a worktree on a detached HEAD, goes by its first agent
  conversation, else by its folder.
  The tabs above the terminal name each conversation.
- **Set Label…** in a row's menu, or a double-click on its name, gives the
  row a label shown in place of its branch. The Git branch keeps its name.
  The field starts from the label, or empty on a row without one.
  **Remove Label**, or clearing the field, hands the row back to its
  branch.
- A labeled row starts its second line with its branch, as in
  "feat/login · 3 files uncommitted", so it still says which worktree it is. A
  fact that only repeats the state, such as "Idle", gives way to the branch
  alone. A worktree with no branch shows its folder there instead, without
  the project's folder name in front. A label that already matches what
  would be shown shows nothing beside it. The worktree menu, **Needs
  Attention**, and **All Projects** say which worktree a labeled row is the
  same way.
- Worktrees whose folder is gone from disk, with no tab open in them, fold
  into **Missing Worktrees**. Worktrees whose PR is merged or closed, with
  nothing open and nothing uncommitted, fold into **Ready to Clean Up**, and
  the ones Git reports that you never opened (an agent's own, for one) into
  **Other Worktrees**.
- Under the pointer, the **Missing Worktrees** line shows **×**, which removes
  its rows from the sidebar, and the **Ready to Clean Up** line shows **×**,
  which deletes its worktrees with `git worktree remove` after a
  confirmation. Their branches stay. A worktree Git would remove only with
  Force gets the same Force confirmation as **Delete Worktree…**.
- Fold a header and it shows what waits inside.
- A header's **+** opens **New Worktree** for that project (⌘N for the
  window's). The **+** beside the sidebar's **Projects** heading opens a
  folder as a project (⌘O).
- The **Scratch** row at the bottom holds terminals that belong to no
  project.

### Session area

The worktree's header with its commits and uncommitted files, the pane strip
of tabs (agents, shells, the review), and the terminal.

The **▾** at the strip's left end (⇧⌘A) opens **Open Tabs**: every tab of the
session, with who runs in it and its state, to search, switch to, or close.
Use it when the strip has more tabs than fit.

Every pane has a one-line header with the pane's name and folder. For an
agent it adds the model, the effort, the permission mode unless it is the
default, and the tokens its conversation's kept turns have used.
When the agent runs every action without asking (Claude Code's bypass mode, or Codex with approvals
set to never), the header says **Runs without asking** beside a warning
sign. As the pane narrows, the folder goes first, then the tokens, then the
model, the effort, and the mode, then the name. The warning stays as its sign.

When tmux shows several agents in one terminal, the header gives priority
to a visible agent that runs without asking, keeping its warning even when
another split has focus. The model and provider name describe that same
agent. Otherwise, the focused agent takes priority. When an agent launches
another CLI in the same tmux pane, settings follow the child while it works.
The header returns to the parent with its next report of its settings, or when the child reports that its session has ended.
Agents in hidden tmux windows or panes hidden by zoom do not supply the
header settings.
If older records do not identify which invocation is current, the header
says **Agent settings unavailable** with a warning sign instead of guessing
the model, effort, or permission mode. A new invocation records its launch order.

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

When a Claude Code turn ends with shells, subagents, or other tasks still
running in the background, the line adds how many, until a later turn ends
with none left. Claude starts that turn itself when a task ends. The row,
the tab, and the pane header show the circling dot meanwhile, and the agent
still counts as finished for **Needs Attention** and notifications. A turn
that fails or is interrupted says nothing about them. Codex does not report
its background terminals, so its line never says this.

### Changes panel

⌥⌘I, off by default. Every conversation's turns in the worktree as one
timeline, with the unviewed count and range, the tokens those turns used,
and a **Conversation** filter.

- Each turn is a card: its prompt and when it started, then what it
  changed, its test runs in order (✗✗✓ failed twice, then passed; a
  fainter ✓ ran only part of the suite), the tokens it used, and how long it
  ran. The token count leaves out what was read from the prompt cache; the
  tooltip has the exact count and everything it is made of. No price is
  shown. When Claude Code's auto mode refused something the agent tried, a
  line names the first action and how many others; the tooltip lists each
  with its reason. Under them, a turn that finished shows the first
  paragraph of the agent's reply, on two lines at most; the tooltip has more
  of it. A finished turn's notification says the reply too, with the prompt
  beside the project.
- Each conversation is named by its title: the name you gave its tab
  (kept after the tab closes; clear the tab's name to drop it), else the
  agent's own (Claude's `/rename` or the title Claude generates,
  Codex's thread name), else its first prompt. An untitled conversation
  beside another of its agent is numbered ("Claude #2"), and so are two of
  one agent with the same title ("Fix tests #2"). The
  **Conversation** filter and the review's scope menu list each by name.
  The line under the name says the tab that runs it, counted as the pane
  strip shows the tabs ("Tab 3"), where it runs when that is another
  worktree, or "No tab" once it ended. When it last worked and its
  unviewed turns follow. The tooltip and VoiceOver name the conversation.
- While a worktree has two or more conversations running or with turns to
  read, each of them gets a color, drawn as a short vertical bar just left
  of its agent badge: on its pane's header, on its pane strip tab and its
  **Open Tabs** row, under the turn number on its cards, in the
  **Conversation** filter and its menu, in the review's scope menu, and on
  the review's file tags. A tab's bar shares its height among the colors of
  the conversations its badge stands for, up to three. A conversation keeps
  its color while it runs or has turns to read, so a pane, a tab, and their
  cards can be matched at a glance. Rest the pointer on a tab and the cards
  of every conversation it runs are outlined in their colors while the others
  fade, or on a pane's header for that pane's alone; point at a card and its
  pane is outlined, or its tab while the pane is behind another tab. A worktree with one such
  conversation, and a scratch tab, show no bar. A file tag still shows the
  number ("#2") when the conversation's name carries one.
- An unviewed turn's number ("T7") stands in a blue pill; a viewed turn's
  number is gray. The card open in the review is ringed in blue.
- The viewed turns at the top of the list fold into one line, **Show 12
  earlier viewed turns** (in each section, by conversation). Click it and
  the cards come back in its place; they fold again when you switch
  worktrees, change the grouping, or reopen the panel.
- A card's moves stand where its time is: **Mark as Viewed up to Here**
  (**Mark as Unviewed from Here** on a viewed turn) and **Restore Code to
  Before This Turn…**. They show on the last card that has them (in each
  section, by conversation) and on the card that says why a restore has to
  wait, and on any other while you point at it, move the keyboard onto it,
  or open it in the review; a running turn has none. Both are also in the
  card's context menu and its VoiceOver actions; the context menu also
  offers **Show Tab** while a tab of this worktree runs the conversation.
- With two or more conversations with turns and the filter on **All**, **Timeline** and
  **By Conversation** above the list choose how the turns are listed; each
  window keeps its choice. **By Conversation** gives each conversation a
  section, the running ones first, then those with unviewed turns, then
  those viewed, the latest first in each. A section's heading shows the
  conversation's color, badge, and name, the same line as the filter's
  menu, its unviewed count, and **Show Tab** while a tab of this worktree
  runs it. Click the heading to collapse the section; it opens again when
  you switch worktrees, change the grouping, or reopen the panel. Its cards
  leave out the badge, which the heading carries. A card's moves reach its
  own conversation's line only, and **Unmark as Viewed** under a section
  takes back that conversation's line alone. Pointing at a heading outlines
  the conversation's tab, as a card does.
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

- **Native approvals.** Weir's approval service holds Claude Code and Codex
  permission requests for the approval card. The release DMG has it. A build
  without a Team ID leaves every approval to the agent's own prompt; see
  [CONTRIBUTING.md](../CONTRIBUTING.md#native-approvals-in-a-debug-build).
- **Worktrees.** Create, switch, and delete worktrees from **New Worktree**,
  the worktree menu, and the sidebar row. When an agent `cd`s into another
  worktree, Weir offers to move the tab there.
- **Pull request status.** A row with an open, draft, merged, or closed PR
  shows the PR's state, with its checks on the mark's corner: failing,
  running, or passed. Hover for the title and checks. Weir uses whatever
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
  (⇧⌘N) keeps the notifications Weir sent. The menu bar icon shows the
  attention state.
- **Shell command.** **Settings → Integrations → Shell Command** adds a `weir`
  command to the terminal: `weir .` opens the current folder as a project.
- **Updates and languages.** Weir checks for updates once a day through
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
