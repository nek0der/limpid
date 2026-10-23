# Limpid

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/nek0der/limpid/actions/workflows/ci.yml/badge.svg)](https://github.com/nek0der/limpid/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/nek0der/limpid?sort=semver)](https://github.com/nek0der/limpid/releases/latest)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)

> A native macOS window for supervising Claude Code and Codex: run them in real terminals, see which one needs you, and review what each turn changed.

<p align="center"><img src=".github/assets/hero.png" alt="A Limpid window. On the left, a sidebar of every project's worktrees, the current project's rows showing each agent's state: unread, waiting, running, stopped on an API error, and a pull request that is open. In the middle, Claude Code running in a terminal tab, with a decision bar under it that sums up two unviewed turns and offers Mark as Viewed and Review Unviewed. On the right, the Changes panel lists the worktree's turns with Mark as Viewed up to Here and Restore Code to Before This Turn buttons. The title bar shows Needs Attention with a count of 6." width="900" /></p>

## Why Limpid

When several agents work at once, the hard part is not typing; it is knowing which one is blocked, what each turn changed, and what you have already read. Limpid keeps the agents in their own terminal UI (built on libghostty) and adds what the terminal cannot show:

- **One list of what needs you.** Approvals, questions, stops, and turns you have not read, across every project, in the order they arrived. ⌘J takes you to the next one.
- **Every turn is recorded.** A *turn* is one round of an agent's work, from the prompt you send until it stops. Limpid snapshots the worktree at the start and end of each turn, so you can review exactly what a turn changed, mark it viewed, or restore the code to before it.
- **One worktree per task.** Each task gets its own branch and folder, with its PR status beside it.
- **You still type in the agent's own prompt.** Limpid inserts your review comments into the agent's input, and you press Return.

**What Limpid is not.** It is not an editor, and it is not an agent. It hosts the agents' own CLIs, Claude Code and Codex, in real terminals and supervises them; the agents do the work.

## Requirements and install

- macOS 26 (Tahoe) on Apple Silicon.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex CLI](https://github.com/openai/codex), whichever you use.

Download the [latest DMG](https://github.com/nek0der/limpid/releases/latest) and drag `Limpid.app` to `/Applications`. Limpid offers updates through Sparkle from then on. The release DMG includes native approvals: Claude Code and Codex permission requests can be answered on Limpid's approval card.

Building from source: [CONTRIBUTING.md](CONTRIBUTING.md#setup). A Debug build runs without native approvals unless you sign it with a Team ID ([details](CONTRIBUTING.md#native-approvals-in-a-debug-build)).

## Quick start

1. **Start.** **New Worktree** (⌘N) makes a worktree on a new or existing branch and opens Claude Code, Codex, a shell, or nothing in it. Give the agent its first instruction in its own prompt.
2. **It works.** The sidebar row and the decision bar show what the agent is doing. Nothing moves or takes focus on its own.
3. **It needs you.** An approval, a question, a stop, or a finished turn joins **Needs Attention**. ⌘J goes to the next item, ⌃⌘J opens the list.
4. **You review.** **Review Unviewed** or ⌥⌘R opens a review tab. Its *scope* menu picks what it shows: one conversation's unviewed turns, all of them in the worktree, a single turn, uncommitted changes, or the branch against its base. Comment on lines, insert the comments into the agent's input, and press Return. You can also discard a *hunk* (one block of changed lines) and undo that.
5. **You decide.** **Mark as Viewed** (⌘⏎) moves the *viewed line*, the mark of how far you have reviewed, past the turns you read. **Restore Code to Before This Turn…** puts the working tree back, and can be undone. **Resume Same Conversation** picks up after a stop.

The [user guide](docs/user-guide.md#the-workflow) has each step in full.

## The window

Each window shows one project at a time. From left to right in the screenshot:

- **Title bar.** Project and worktree menus, the command palette, and **Needs Attention**.
- **Left rail.** Show or hide the **Worktrees** sidebar, and open **All Projects**, **Notification History**, and **Settings**.
- **Sidebar.** Every project's worktrees, one row each, with what each agent is doing.
- **Session area.** The worktree's commits and changes, its tabs, and the terminal.
- **Decision bar.** Under each agent pane: what the unviewed turns did, and what to do about them.
- **Changes panel** (⌥⌘I). The worktree's turns as one timeline, and **Commit & PR**.
- **Status band.** Where you are, the agent, the folder, the terminal size, and the encoding.

The [user guide](docs/user-guide.md#the-window) covers each part in detail.

## More

- **Pull request status.** Each row shows its PR's state and checks, through whatever `gh` or `glab` is already signed in.
- **Session restore.** Projects, worktrees, tabs, splits, windows, and scrollback come back after a relaunch, and agent panes resume their conversations.
- **Quick Terminal.** A system-wide hotkey drops a terminal over any app; set one in **Settings → Quick Terminal**.
- **All Projects** (⌥⌘O) and **Notification History** (⇧⌘N). Every project at once, sorted by state, and the notifications Limpid sent.
- **Languages.** English and Japanese; choose in **Settings → General → Display Language**.

## Privacy and data

Limpid has no account, analytics, or telemetry.

**Network.** Limpid itself reaches the network in three ways:

- **Update checks.** Sparkle fetches `https://nek0der.github.io/limpid/appcast.xml` once a day and downloads a release only when you choose to install it. Turn the daily check off with **Settings → General → Software Update → Automatically check for updates**; **Check for Updates…** still works by hand.
- **`git fetch`.** When **New Worktree** starts a new branch from a remote branch or checks out a PR, Limpid fetches it from that remote with your own Git credentials.
- **`gh` and `glab`.** Limpid runs the copies you installed, which talk to the forge with their own credentials: `gh pr view` or `glab mr view` for the sidebar's PR status (when the app comes back to the front, every 5 minutes, and every 45 seconds while checks run), `gh auth token` or `glab auth status` once per host to tell which forge an unfamiliar host is and before **New Worktree** offers to check out a PR, `gh pr list`/`view` or `glab mr list`/`view` when **New Worktree** checks out a PR, and `gh pr create --fill` when you press **Create PR**.

**What Limpid writes or installs.**

- **Codex config.** When `~/.codex/` exists, Limpid keeps one `[hooks.state."/<session-flags>/config.toml:…"]` table per hook in `~/.codex/config.toml`, between `# BEGIN limpid` and `# END limpid` markers. In each it sets only `enabled = true` and `trusted_hash`, because Codex runs a hook only when its hash is trusted in your own config. A Limpid table already elsewhere in the file is updated where it stands. Every other line, including a table Codex adds between the markers, stays as it is. The tables are re-applied at every launch, so one you delete or disable comes back. The hooks themselves are not in the file: Limpid's `codex` shim passes them as `-c` flags, along with two terminal-title and notification settings, only in Limpid's panes.
- **Claude Code hooks.** Nothing is written to `~/.claude/`. Limpid's `claude` shim, first on the `PATH` of Limpid's panes, passes the hooks with `--settings` on each launch, filled in from a template the build copies into the app. It merges a `--settings` of your own, and keeps links to the hook commands in a `limpid-claude-shim-*` folder in your temporary directory.
- **Approval service.** A build signed with a Team ID, such as the release DMG, registers a per-user launchd agent, `dev.limpid.agent-integration-service`, from inside the app. It is listed in **System Settings → General → Login Items & Extensions**.
- **Turn snapshots.** In each repository, the snapshots live in the Git directory as refs under `refs/limpid/` and files under `limpid/`. A turn and its refs are deleted after 14 days or past 200 turns per conversation (change this in **Settings → Advanced → Turn History**), or when a repository's snapshots pass 500 MB or all turns pass 8,000; Git can then reclaim the space. Unviewed turns of open sessions are exempt from the day limit for up to 90 days.
- **Under `~/Library`.** `Application Support/Limpid/` (`Limpid Dev/` for a Debug build) holds the session, settings, notification history, scrollback, review drafts, and turn records. Preferences are in `Preferences/dev.limpid.Limpid.plist`.

**Uninstalling.** Quit Limpid and move `Limpid.app` to the Trash. Then remove by hand: `~/Library/Application Support/Limpid/` and `~/Library/Preferences/dev.limpid.Limpid.plist`; the `# BEGIN limpid` … `# END limpid` lines and the tables Limpid wrote in `~/.codex/config.toml` (keep any of your own between the markers); and in each repository, the refs (`git for-each-ref --format='%(refname)' refs/limpid/ | xargs -n1 git update-ref -d`) and the `limpid` folder in its Git directories. If **Login Items & Extensions** still lists Limpid, turn it off there. Worktrees Limpid made are ordinary Git worktrees; remove them with `git worktree remove` if you no longer want them.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌘J / ⇧⌘J | Next / previous item that needs you |
| ⌃⌘J | Show Needs Attention |
| ⌘⏎ | Decision bar's main action (Mark as Viewed, Resume, Notify When It Resets) |
| ⌥⌘R | Review |
| ⌥⌘I | Changes panel |
| ⌘N | New Worktree |
| ⇧⌘P | Command Palette |
| ⌘/ | Keyboard Shortcuts |

⌘/ shows the full list with your own bindings, and **Settings → Keyboard** changes the keys. The [user guide](docs/user-guide.md#shortcuts) has every default.

## Status

Pre-alpha. Settings and data formats may still change between releases; Limpid migrates its files forward, and [Going back to an earlier build](docs/data-migration.md#going-back-to-an-earlier-build) says how to return to one. [Known limitations](docs/known-limitations.md) lists what does not work yet and the deliberate behavior that may surprise you.

## Documentation

- [docs/user-guide.md](docs/user-guide.md) — the window part by part, the workflow in full, and every shortcut.
- [ARCHITECTURE.md](ARCHITECTURE.md) — module map, the supervision window part by part, load-bearing files, invariants, and "How to add X" walkthroughs.
- [AGENTS.md](AGENTS.md) — repo conventions and Swift style (for humans and agents).
- [docs/known-limitations.md](docs/known-limitations.md) — what does not work yet, what is surprising on purpose, and what has not been checked on a real machine.
- [docs/data-migration.md](docs/data-migration.md) — the files Limpid keeps, how they are migrated, and how to go back one release.
- [docs/agent-integration-protocol.md](docs/agent-integration-protocol.md) — the contract between the hook helper, the approval service, and the app.
- [CONTRIBUTING.md](CONTRIBUTING.md) — setup, build, signing for native approvals, and the PR workflow.
- [SECURITY.md](SECURITY.md) — vulnerability reporting policy.

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). Questions and ideas go in [Discussions](https://github.com/nek0der/limpid/discussions).

## Acknowledgements

Built on [Ghostty](https://github.com/ghostty-org/ghostty) (libghostty) and [Sparkle](https://github.com/sparkle-project/Sparkle). The full third-party list is in [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES); the build fills in its Rust crates from `Cargo.lock`, and the copy inside Limpid.app carries them.

## License

[MIT](LICENSE) © 2026 nek0der
