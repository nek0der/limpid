# Migrating saved data

Limpid keeps its state in files under `~/Library/Application Support/Limpid/`
(`Limpid Dev/` for a Debug build), and keeps a few more in each repository's
Git directory. When the shape of a versioned file changes, its version goes
up and Limpid brings the file forward at launch. This document describes how
that works, lists every file the supervision window's release changes or adds,
and says how to go back one release after a migration.

Paths below are relative to the Application Support folder unless they name a
Git directory.

Two names for older builds recur below. "The previous release" is the last
release before the supervision window. "The build before" is the build of this
release that came just before the change being described.

## How it works

- `VersionedDocumentMigrator`
  (`Limpid/Core/Persistence/VersionedDocumentMigrator.swift`) reads a file's
  version and runs the steps that bring it to the current one. Each document
  describes the key that holds its version (`version` or `schemaVersion`), its
  current version, and one step per older version (`DocumentMigrationStep`).
- The migrator only reports what it found. What happens to a file it cannot
  bring forward is up to each document. For `state.json`, the file is renamed
  with its contents unchanged and Limpid opens a fresh window:
  - written by a newer build, or too old for any step:
    `state.json.bak-version-mismatch-<unix>`
  - a step failed: `state.json.bak-migration-failed-<unix>`
  - the copy described below could not be taken:
    `state.json.bak-backup-failed-<unix>`
  - the migrated file does not decode: `state.json.bak-decode-failed-<unix>`
  - the file is there but cannot be read (its permissions, an I/O error):
    `state.json.bak-read-failed-<unix>`. Only a file that is not there at
    all starts Limpid as a first launch, with nothing to report. A file in
    a folder that cannot be searched is not taken for a missing one. It
    cannot be moved either, so Limpid stops saving for the launch.

  For `settings.json`:
  - A file that is there but cannot be read is renamed
    `settings.json.bak-read-failed-<unix>`, and Limpid starts from the
    defaults. As for `state.json`, only a missing file counts as none, and
    one in a folder that cannot be searched stops saving for the launch.
  - A file written by a newer build is still read, so rolling back through
    Sparkle does not reset the settings. One that does not decode here (the
    newer build changed the type of a key this build knows) stays where it
    is, unrenamed. Limpid runs on the defaults for that launch and does not
    save them over it.
  - A file that cannot be copied before its migration is read as it was and
    not written. The next launch tries again. Changes made in that launch are
    not saved, and Limpid says so at launch and at the top of
    Settings → General.
  - A file that is not newer than this build (or whose version cannot be
    read) and that neither moves to the current format nor reads as it
    stands is renamed
    `settings.json.bak-decode-failed-<unix>`. Limpid then starts from
    the defaults and saves them.

  For a review draft (`reviews/<hash>.json`):
  - A draft written by a newer build is renamed
    `<hash>.json.bak-newer-version-<unix>`, and one too old for any step is
    renamed `<hash>.json.bak-decode-failed-<unix>`. The review starts empty.
  - A draft that cannot be copied before its migration is used as migrated
    but not written, and the review says its changes are not saved. They are
    lost when the review closes. Opening the review again reads and migrates
    the file afresh.
  - A migrated draft that would exceed the 2 MB limit is renamed
    `<hash>.json.bak-migration-too-large-<unix>`.
- Sometimes this build cannot use a `state.json` or `settings.json` and cannot
  rename it aside either (a read-only folder, an immutable file). Limpid then
  leaves the file in place and does not save it for the rest of that launch,
  so the only copy is never overwritten. Changes made in that launch are not
  kept. Limpid says so at launch: in the alert that the session was not
  restored, or in an alert of its own for `settings.json`. It also says so at
  the top of Settings → General for as long as saving stays stopped. A review
  draft in that position is handled the same way: the review starts empty, is
  not saved, and loses its changes when it closes. Opening it again tries the
  file afresh.
- Before a migrated file is written, `MigrationBackup`
  (`Limpid/Core/Persistence/MigrationBackup.swift`) copies the original to
  `<name>.pre-v<N>` beside it. `<N>` is the version the file moves to, and the
  copy is readable by the user only (0600). If the copy cannot be written, the
  file is not migrated. An existing copy is reused only after it is read back
  and found to hold exactly the original's bytes.
- The migrated file is written right away rather than on the next save. The
  ledger, `<name>.migration.json` beside the file, records the SHA-256 of the
  bytes written. It moves to `written` once they are on disk. A relaunch
  counts the migration as written only if the file holds exactly those bytes.
  If that first write fails, the migrated document stays in use from memory,
  and the first save that reaches disk finishes the ledger with the bytes it
  wrote (`state.json`, `settings.json` and review drafts alike). If Limpid
  ends after the write but before the ledger update, the next read of the
  file finds exactly the recorded bytes and finishes the ledger. The ledger
  stops at `written`: nothing on screen reports a migration, and only the log
  records it. `acknowledged`, which earlier builds wrote once they had told
  the person, is kept only so that the ledgers they left still read.
- The ledger also records the original file's SHA-256. If Limpid ends anywhere
  between the copy and the ledger update, the next launch finds the same copy
  (through the ledger, or by comparing the copies' contents) instead of taking
  another one. A new generation, `<name>.pre-v<N>.<unix>`, is taken only when
  the original has changed since, for example after an earlier build ran and
  saved again.
- Copies are not cleaned up. Going back and forth between builds keeps one
  copy per distinct original, which is at least the one generation the design
  asks for. The one exception is a review draft whose worktree is deleted:
  the draft goes with its copies, its ledger, and any draft set aside, since
  all of them quote that worktree's code.
- Nobody is told about a review draft's migration: there is one draft per
  repository, and nothing on screen changes. Its ledger moves to `written`
  as soon as the migrated draft is written, like the others.

## File by file

| File | Change | Copy before the change |
|---|---|---|
| `state.json` | version 5 → 6 | `state.json.pre-v6` |
| `settings.json` | schema 1 → 2 | `settings.json.pre-v2` |
| `reviews/<hash>.json` | version 1 → 2 | `reviews/<hash>.json.pre-v2` |
| `notifications.json` | two optional fields, no version | none |
| `worktree-routing.json` | still version 1, two optional fields | none |
| Run records (`agent-states/`, `codex-agent-states/`) | still schema 3, seven optional fields | none |
| Turn records and counters (`<state>/turns/`) | new | — |
| `turn-reads.json`, `viewed-lines.json` | new | — |
| `stops.json` | new | — |
| `ended-session-hints.json` | new | — |
| `turn-deletions.json` | new | — |
| `restore-pending-stops.json` | new | — |
| `pane-path-<project ID>.txt` | new: the `PATH` the last shell of a pane of that project ended up with, where an agent is looked up for that project | — |
| Codex's `~/.codex/config.toml` (the person's own) | same keys; our tables are rewritten in place instead of the whole span between our markers | none |
| Refs and files in each repository's Git directory | new, and one no longer written | — |

### `state.json`: version 5 to 6

The step is `SessionSnapshotV5`
(`Limpid/Core/Persistence/SessionSnapshotV5.swift`):

- Groups are no longer written. Their tabs become scratch tabs, after the
  scratch tabs that were there, in group order and then tab order. Each tab
  keeps its group's name as a prefix to its title ("prod · ssh"), the group's
  color as a mark on the tab, and the group's working-directory default for
  the tab's new panes. A group that recorded no default, or recorded it as
  `null`, had "continue where the active tab is", and its tabs keep that:
  their new panes start in the folder the tab was last in, not where it
  opened. So do the tabs of a group whose default names no mode. A tab of a group that no longer exists becomes a plain scratch
  tab. The groups' folding and last-used tab are dropped.
- What the window showed and how it was laid out moves from the root of the
  file into the first entry of `windows`, on the project its selection was
  in. That window starts with the sidebar at its default width. The tab
  column's orientation and width and the Waiting region's height are dropped,
  because a window now shows its tabs only as the pane strip. The root keys
  that moved (`SessionSnapshotV5.movedRootKeys`) are removed rather than
  carried as unknown fields. If the file already listed more windows, those
  after the first keep their own records. A tab column's orientation or width
  in one of those records is passed over and not written again. The step
  takes `windows` one element at a time: an element that is not a record
  (`null`, a string) is passed on as it is, and version 6 then passes over
  that one window alone (below). A first element that is not a record leaves
  the primary on what the root held.
- Projects keep the `containers[]` shape. The worktree hook no longer reads
  `state.json`; it reads `worktree-routing.json`, written beside it.
- How many groups and tabs moved goes to the log only.

A version 4 or older file has no step and is set aside, as before.

Version 6 keeps the name a person gives a sidebar row on the row itself:
`displayName` on a worktree, and `rootDisplayName` on a project for its own
folder's row (`Worktree` and `Project` in `SidebarItem.swift`). Both are
optional and written only when set; a file without them reads as rows with no
name of their own, and a value of another type reads as none. Renaming a row
writes only that key, and an empty name removes it.

No name moves, in the step or at load. A row is named by its own name, then
by a name one of its tabs was given (`titleOverride`), then by its
conversation, branch, or folder (`WorkspaceSession.rowName(of:)`). So a name a
version 5 tab carries, and one the build before kept on a row's first tab when
the row was renamed, stays on that tab and still names the row. Renaming the
row never clears a tab's name either: that name may be the one the pane strip
shows. The one exception is clearing the name of a row that has none of its
own: the row showed a tab's name, so that is the name the person cleared, and
it comes off the tab. Otherwise it would name the row again at once.

The build before carries both keys as unknown fields on the worktree and the
project, writes them back unchanged, and names the row by its tabs. A row
renamed in the build before keeps that name on a tab, so back in this build
the row's own name, if it has one, goes ahead of it. The
previous release never reads a version 6 file (see "Going back to an earlier
build"); its worktree and project decoders would pass over both keys. The
`state.json.pre-v6` copy holds no row names, so a name given in this release
is not in it.

Version 6 reads some values it never writes, so that a file another build of
this release wrote still opens:

- A container of a kind it does not know (a group, or a newer build's) is
  passed over and logged rather than failing the file
  (`SessionSnapshot.swift`, `OptionalContainer`).
- A tab whose container names a group (`{"group": {"_0": …}}`) or another
  unknown kind is a scratch tab (`ContainerID.init(from:)` in `Tab.swift`).
  The next save writes it as one.
- A project's `isExpanded`, which the sidebar's folding wrote, is passed over
  and not written again (`Project.init(from:)` in `SidebarItem.swift`).
- A window record's `tabOrientation` and `tabColumnWidth`, from when a
  window could set its tabs in a column, are passed over and not written
  again (`WindowRecord.swift`). A record that says `column` opens on the
  strip. The build before reads a record without them as the strip at the
  default width.
- A window record that cannot be read costs only that window's layout: a
  later window is passed over, and the primary window starts from its
  defaults. A project's saved view (`projectViews`) that cannot be read costs
  only itself.

Keys version 6 does not know are written back as they were at the root of
the file (`SessionSnapshot.unknownFields`), on each tab (`Tab.unknownFields`),
on each project (`Project.unknownFields`), and on each worktree
(`Worktree.unknownFields`). A key a newer build adds there survives a round
trip through this build. That includes a key a version 5 file carried on a
tab, which the step passes on. The keys this build reads and no longer writes
are not carried: a tab's per-provider fields (`claudeSessions` and the rest)
and a project's `isExpanded`. Nothing else in the file keeps a key it does not
know. Window records and projects' views are made again from the open windows
at every save, and a worktree's `gitRef`, a tab's panes and its split tree are
replaced as they change. So a newer build that adds a key to one of those
records loses it to a save by this build. So does a closed tab reopened with
⌘⇧T, which is made again on new pane IDs that a carried key could not follow.
A change that must survive that needs a version bump.

Some keys of version 6 were added later than others. A build that predates a
key skips it:

- A project's `mainHeadSHA`, the commit its main folder has checked out, is
  read with `decodeIfPresent` (`Project.init(from:)` in `SidebarItem.swift`).
  A file without it reads as no commit until the next sync fills it in.
  Limpid uses it to keep offering the worktree menu for a main checkout on a
  detached HEAD. A build without it skips the key.
- A tab's `conversationName`, the name of the first agent conversation that
  ran in it, names the tab's session row (`Tab.swift`). A file without it
  reads as a tab no agent has named. A build without it skips the key, and
  drops it if that build saves the session. This release then names the tab
  again only while its agent still runs.
- A worktree's `gitRef` still writes `ahead`, `behind`, and `isDirty` as 0, 0,
  and `false`, although nothing here reads them (`GitRef.encode(to:)` in
  `SidebarItem.swift`). An older build requires them, and without them it
  would fail to read the whole session. That build shows a clean, even tree
  until its own sync runs.
- A worktree's `admission` (`containers[].project.worktrees[].admission`)
  says how it became a sidebar row: `"created"` (Limpid made it), `"opened"`
  (the person opened it), or `"discovered"` (Git only reported it). A
  discovered worktree with no tab is listed among the other worktrees rather
  than the working rows (`Worktree` in `SidebarItem.swift`,
  `WorktreeAdmission.swift`).
  - A file without the key is placed once, at the next sync, and the value is
    written at the next save. Use comes first: a worktree with a tab, a
    `lastActiveTabID`, or a selection (a window's, or one in `projectViews`)
    is `"opened"`. Only a worktree with none of them is placed by its path:
    under `/.claude/worktrees/`, under `~/.codex/worktrees/<id>/`, in a
    folder named `agent-…`, or on a detached HEAD, it is `"discovered"`, and
    otherwise `"opened"` (`WorktreeAdmissionRule`). Until then the row is
    treated as one the person had, so no row leaves the working rows before
    the first sync.
  - A value this build does not know, or a value of another type, reads as
    no admission and is not written back. The row is placed again as above.
  - A worktree a hook routed to the project's own placement sits where
    Limpid puts its own, so its path does not tell it apart. It stays
    `"opened"`.
  - The build before skips the key and drops it when it saves. Coming back
    to this build places the worktrees again, so a row that was only
    selected, with no tab opened in it, can return to the other worktrees.
- A project's `ignoredFilesToCopy`
  (`containers[].project.ignoredFilesToCopy`) is an optional array of
  strings: the paths and patterns of the files Git ignores that each new
  worktree gets a copy of from the project's folder (`Project` in
  `SidebarItem.swift`). A file without it copies nothing, as an empty list
  does. The build before skips the key and drops it when it saves, so a
  round trip through that build loses the list.
- A window record's `sidebar` (`windows[].sidebar`) is how that window's
  sidebar lists the projects: `projectOrder`, the project IDs in the order
  the person left them; `collapsedProjects`, the IDs of the folded headers;
  and `openSections`, the folded sections the person opened, each
  `{"project": <UUID>, "section": "cleanable" | "other"}`
  (`SidebarArrangement.swift`, `WindowRecord.swift`). The version stays 6.
  - It is written with its sets sorted, so the same arrangement saves the
    same way each time. A window whose arrangement is still empty (its
    sidebar has not met a project yet) writes no key.
  - A record without the key, or with one that cannot be read, lists the
    projects in the `containers[]` order. The first time the sidebar meets a
    project, it folds or opens the project's header once by the default rule
    (the window's own project, and one with two or more working rows, open;
    a project another window shows folds) and writes that down, so a header
    does not fold or open later by itself. Each of the three fields is read
    on its own. An `openSections` entry that names a section this build does
    not know (or the working rows, which have no fold) is passed over. An ID
    of a project the session no longer has is let go at launch.
  - Only the last window closed is saved as hidden, so the order and folds
    of any other window hidden at quit are not kept across a relaunch.
  - The build before skips the key and drops it when it saves, so a round
    trip through that build returns every window's sidebar to the default
    order and folds.

Some keys of version 6 are still read but no longer written new:

- A tab's `initialPromptFiles` (`tabs{}.initialPromptFiles`) names, per pane,
  the 0600 file holding a first instruction that an earlier build's new
  workspace sheet staged (`Tab.swift`, `InitialPromptFile.swift`). The sheet
  no longer takes an instruction, so this build writes no new entry. It
  still reads the ones a restored tab has, carries them when a pane moves,
  saves them, and hands each to its pane's first agent launch, so an
  instruction staged before the update is not lost. The release after this
  one removes the key from `Tab.CodingKeys`, after which it is skipped.
  `InitialPromptFile`, the shim's `limpid_take_initial_prompt`, and the
  `unsetenv` and `removeOrphans` calls in `LimpidApp` go with it. The build
  before reads and writes the key as this build does.

Some keys of version 6 are no longer read or written:

- `changesPanelAgent`, in a window's record (`windows[]`) and in a
  project's saved view (`projectViews[]`). It named the agent that the
  changes panel's switcher showed. The panel now lists every conversation's
  turns as one timeline and narrows it with a filter. The filter opens on
  "All" at every launch, is kept while the app runs, and is never written
  (`WindowSelection.changesPanelFilter`), so an old choice does not come
  back as a narrowing. A file that holds the key reads as if it did not.
  The build before reads a file without it as no choice made, and follows
  the focused pane, as it does before the person chooses.

Some keys of version 6 are still written but no longer read:

- A project's saved view (`projectViews[]`) still writes `sidebarWidth`,
  `sidebarHidden`, `isChangesPanelPresented`, and `changesPanelWidth`
  (`ProjectView.swift`), but this build does not lay a window out from them.
  The sidebar and the changes panel are the window's chrome now. A window
  keeps their width, and whether they are shown, as it switches projects. It
  saves them in its own record (`windows[]`), which already held them. The
  selected container and tab stay with the project.
  - A file the build before wrote reads without change: each window takes
    the chrome in its record. A window with no readable record takes the
    chrome its project's view kept, rather than the defaults
    (`SessionSnapshot.swift`, `restore(from:)`).
  - The build before reads these keys to lay a window out as it switches to
    the project, and it still opens a file this build wrote. In these keys it
    finds the chrome of the window that last left the project. They are
    written for that build only, so that going back to it does not open every
    project at the default widths.
  - They can be dropped from the writing side in the release after this one,
    once going back means going back past the build before. A view without
    them already reads (`ProjectView.init(from:)` uses `decodeIfPresent`),
    so dropping them needs no version bump. They then move to the list
    above, as keys passed over and not written again.

The previous release reads version 5 only. A version 6 file fails to decode
there before its version is even compared, because version 6 drops keys that
version 5 requires. The first one its decoder reaches is a project's
`isExpanded` (`containers[0].project.isExpanded`), and the root's selection
keys (`activeContainerID`, `sidebarWidth`, `sidebarHidden`) are gone as well.
The previous release sets the file aside as
`state.json.bak-decode-failed-<unix>` and opens a fresh window.

### `settings.json`: schema 1 to 2

`settings.json` moves from schema 1 to 2 (`VersionedDocumentMigrator.settings`,
`Limpid/Core/Settings/SettingsMigration.swift`) for the supervision window's
shortcuts. Two rules apply:

- A binding on ⌘⏎, which the decision bar now reserves, moves to
  `keyboard.retired`. Settings → Keyboard lists it there until it is
  discarded. A quick terminal hotkey on ⌘⏎ moves there too, and the hotkey is
  then unset.
- A new action whose default keys are already held by one of the person's own
  bindings, or by the quick terminal's hotkey, starts unbound
  (`keyboard.unbound`). It gets its default back once those keys are free.

Both rules are also applied on every load and every change
(`KeyboardSettings.normalize`), so a file an earlier build saved at schema 2
is brought back in line. The renamed actions keep their stored names
(`reviewChanges`, `reviewTurn`, `nextSection`, `previousSection`), so their
bindings carry over unchanged.

New Workspace… (`newSession`), which only earlier builds of this release had,
is folded into New Worktree… (`newWorktree`), whose default is now ⌘N
(`KeyboardSettings.foldActions`, run first by `normalize`, so on every load):

- A binding saved for `newSession` moves to `newWorktree`, unless
  `newWorktree` has a choice of its own (a binding, or the person's
  Unassign). Then `newWorktree` keeps its own, and the `newSession` binding
  moves to `keyboard.retired` under its old name, which Settings → Keyboard
  lists as New Worktree… until it is discarded.
- `newSession` in `keyboard.unassigned` becomes `newWorktree`, under the same
  condition. `newSession` in `keyboard.unbound` is dropped; `normalize`
  rebuilds that list.
- Nothing is left under `newSession`, so a second run changes nothing. A
  build that still has New Workspace… finds no binding for it and gives it
  its default, ⌘N, unless `newWorktree` holds ⌘N.
- A schema 1 file never had `newSession`. Its `newWorktree` binding (the
  previous release's default was ⌥⌘N) stays as it was; with none,
  `newWorktree` gets ⌘N.
- The move from schema 1 also notes a key whose meaning changed: when the
  file has no choice of its own for `newWorktree` (no binding, not
  unassigned) and Create Worktree Now ends up on ⌥⌘N,
  `keyboard.keysToIntroduce` gets `"newWorktreeNow"`
  (`KeyboardSettings.noteChangedKeys`). That person's first Create Worktree
  Now, while it is still on ⌥⌘N, opens the New Worktree… sheet once with a
  note saying the keys now create at once and the sheet is ⌘N, and the
  entry is then removed. The list is written only while it is not empty.
  The previous release carries it through `KeyboardSettings.unknownFields`.
  A new install, which has no settings file of the previous release, and a
  schema 2 file never get it.
- A person who kept New Workspace… on its default ⌘N and bound New
  Worktree… to other keys, which only earlier builds of this release allowed,
  is not told that ⌘N now does nothing: the file holds nothing that says
  ⌘N was in use.

Move Project Up (`moveProjectUp`) and Move Project Down (`moveProjectDown`)
are new, with ⌥⌘↑ and ⌥⌘↓, the keys Focus Pane Above and Below have too
(`LimpidShortcutAction.sharesKeys`). The two pairs may share keys, because
the sidebar takes them only while it has focus. A person's own
binding on those keys for any other action gives both defaults up
(`keyboard.unbound`), as for any new action.

An action the person left with no keys (Keyboard's Unassign) is listed in
`keyboard.unassigned`. This list is kept apart from `keyboard.unbound`, which
`normalize` rebuilds. A default given up to another binding comes back once
its keys are free; an action the person unassigned stays off until they
restore it. A build without the `unassigned` key reads it as absent and
carries it through `KeyboardSettings.unknownFields`, so in that build the
action has its default keys.

A binding saved for an action this build no longer has, such as Toggle Tab
Layout (`toggleTabLayout`), stays in `keyboard.overrides` as it was. In this
build it binds nothing and holds no keys, and a build that still has the
action finds it.

Two keys are no longer read: `advanced.showPRStatusInSidebar` and
`advanced.showPRStatusOnlyWhenAttention`. Pull requests now show wherever
`gh` or `glab` can read them. The values stay in the file
(`AdvancedSettings.unknownFields`) and are written back as they were.

`general.isFirstRunGuideDismissed` is no longer read, and a file this build
creates never gains it. The first-run guide it recorded is gone until
onboarding is designed. A file from a build that showed the guide keeps the
key as it was (`GeneralSettings.unknownFields`), so going back to that build
does not show the guide again. On a file this build created, such a build
shows its guide once, as on any first run. `general.movedGroups`, which
counted the groups moved to scratch tabs for that guide, is passed over and
not written back.

The new worktree sheet keeps what it opened and how it made a worktree in
`newSession`, still at schema 2 (`NewSessionSettings` and
`NewWorktreeProjectMemory` in `SupervisionSettings.swift`):

- `newSession.lastOpen`: what the sheet last opened in a worktree it made
  (an agent's raw value, `"shell"`, or `"nothing"`). A value this build does
  not know reads as no choice, and the sheet starts from the next one.
- `newSession.fetchesBeforeCreate`: whether to fetch the base's remote first.
  It defaults to true and is written only when false.
- `newSession.projects[path].open`, `.copiesIgnoredFiles`, and `.runsSetup`:
  one project's last choices. A missing `copiesIgnoredFiles` or `runsSetup`
  reads as on.
- `keyboard.overrides.newWorktreeNow`: a binding for Create Worktree Now, whose
  default is ⌥⌘N. A person's own binding on ⌥⌘N wins, and the default starts
  unbound, as for any new action.

The keys an earlier build of this release wrote for the sheet,
`newSession.lastAgent` and `newSession.projects[path].agent` and `.location`,
are read only to choose the first selection while `open` is not set
(`"none"`, that build's terminal, reads as the shell). They are written back
as they were read and never changed, so going back finds them. Both sections
carry keys they do not know (`unknownFields`), so the build before keeps the
new keys through a round trip, and this build keeps the old ones.

The previous release reads a schema 2 file and keeps its values. It carries
the following as unknown fields: the sections it does not know (`review`,
`general`, `newSession`), the new keys in `advanced` (`turnRetention`,
`approvalHoldWhileHidden`), and the keyboard's `retired`, `unbound`, and
`keysToIntroduce`. It reads the two pull request switches as the person left
them, and writes the file back at schema 2.

A `settings.json` whose schema is newer than this build's is read and not
written back (`SettingsStore`, `.newerVersion`). Saving stops for the launch,
and Settings says the settings are not being saved. A newer file this build
cannot decode is not set aside either: it stays at `settings.json` for the
newer build, this launch runs on the defaults, and saving stops the same way
(`.newerVersionUnreadable`, which Settings tells apart). A save would write this
build's schema under the newer number. The newer build, seeing its own
number, would then skip the step that moves a value to where it now lives.

### Review drafts: version 1 to 2

Review drafts move from version 1 to 2 (`ReviewDraftMigrator`). In version 2,
each comment and read mark belongs to the comparison it was made in (its
scope).

- Comments on uncommitted changes keep their scope.
- Comments written on a turn or a branch become legacy comments (the draft's
  `legacy` list), because version 1 did not record which turn's snapshot or
  which base branch they were compared against. They stay visible. They move
  into a scope only when the person chooses one and the comment still
  matches its code there.
- The read marks of uncommitted changes are kept; those of turns and
  branches are dropped.
- The file that was open is kept if it was an uncommitted change.
- A draft version 1 itself would have refused is set aside as
  `<hash>.json.bak-decode-failed-<unix>` rather than migrated: no
  `comments` list, a comment or read mark that is not an object, read marks
  that are not an object, or an open file that is not a string. A missing or
  `null` `viewed` or `lastFileID` reads as none, as it did in version 1.

A version 2 comment whose only scopes are `turn:<tree>` also reads as legacy
(`ReviewComment.isLegacy`). Earlier builds of this release wrote that scope
for the per-pane "This turn" review. The `turn` layer it names still decodes.

The previous release reads version 1 only. It sets a version 2 draft aside as
`<hash>.json.bak-decode-failed-<unix>` and starts that review empty.

A version 2 range (`ReviewTurnRange`) now also carries `conversations`: every
conversation with a turn in the range. It sits beside `conversation`, which
names the last turn's conversation. The changes panel's "Review Unviewed" uses
it to read the worktree's unviewed turns as one range across conversations.
The key is additive:

- A draft written before it decodes as a range of its one conversation.
- A build from before it reads a draft written with it as the range of the
  conversation that `conversation` names. The two trees it compares are the
  same, so the diff it shows is the same. Rewriting the draft drops the key.
- Such a build refuses one case: a range across conversations whose last
  turn's number is lower than its first's (Claude's T4 then Codex's T1). It
  sets that draft aside as `<hash>.json.bak-decode-failed-<unix>` and starts
  empty, as for any shape it cannot read.

A range also carries `endTurnID`, the turn whose end it compares. That is the
turn that ended last. It need not be the range's last turn in the timeline's
order (by when each turn started): a turn that started early and ran long
ends the range. `lastNumber` is that turn's number, and `conversation` is its
conversation. The key is additive. A draft written before it decodes with its
last turn as the end turn, which is what its range ended at. A build from
before it skips the key and reads the same two trees. Such a build refuses a
range whose first number is higher than its end turn's within one
conversation (a turn that started before the one numbered before it), as
above.

The review tab has one scope menu, which chooses a conversation's turns or
the worktree's. It adds nothing to the draft: what the tab reads belongs to
the window and is not saved, and the ranges it reads are written as above.
For the drafts, going back one generation therefore means:

- every comment and read mark of a range of one conversation, and every
  draft that holds no range across conversations, reads as it did;
- a range across conversations whose last turn's number is not lower than its
  first's reads as its last conversation's range. It compares the same two
  trees, so its comments are still checked against the same diff. The
  earlier build names it by that conversation's numbers ("T1–T4"), and
  rewriting the draft drops `conversations`;
- a draft with a range whose last number is lower than its first's, across
  conversations or within one, is set aside, as above. Insert the comments on
  it before going back, or rename the set-aside file back once this build
  runs again.

### `notifications.json`

Unversioned, at most 500 rows. Rows now also record their container
(`containerID`) and, for an approval or a question, the request they
announced (`requestKey`). With these, a row can name its place after the pane
is gone and can open the request's card. Rows written before have neither and
fall back to the label recorded with them. A file that cannot be read is set
aside as `notifications.json.bak-read-failed-<unix>` or
`.bak-decode-failed-<unix>`. When it cannot be moved, it is left in place and
saving stops for that launch.

The previous release ignores the two fields and drops them when it next
saves. Those rows then name their place by the recorded label.

### `worktree-routing.json`

Written beside `state.json` by every save, for the hook. Still version 1.
Each project now also lists its worktrees and its check commands
(`worktrees`, `checks`, both optional). The previous release's hook reads the
file and ignores them.

### Run records

The hook's run records (`agent-states/<id>.state.json` for Claude,
`codex-agent-states/<id>.state.json` for Codex) stay at schema 3 and gain eight
optional fields. The first five are `worktreeRoot`, `currentTurnId`,
`usageLimit`, and, while a run waits at its prompt, `waitKind` (`approval` or
`question`) and `tool` (the tool it waits to use). A record without the last
two is worded from its `detail`, as before. The previous release carries
fields it does not know through its records' unknown fields, so a rewrite
keeps them. For `waitKind` and `tool` that can mislead: the previous release
carries them past the wait they described. After going back and forth, a
later wait can therefore read as the earlier one's kind until this release
writes the record again.

The sixth, `outsideTurnRest`, is set while a run works outside a turn. It
holds the rest state (`idle` or `finished`) that the idle prompt returns the
run to (ADR 0004, "Work outside a turn"). The previous release carries it the
same way, but that release never ends such work. A record it rewrites
therefore keeps the field until this release writes the record again. A
record without the field returns to `finished`. A run that the previous
release left running after a late tool has no `outsideTurnRest`, and this
release ends it at the next idle prompt as `finished`.

The seventh, `hasPrompt`, says whether the session holds a conversation. It is
`true` once a prompt is given in the run or when the session resumed one. It
is `false` for a session started anew (or cleared) that has had no prompt
since. A relaunch quietly retires a run whose record says `false`, since
there is no transcript for a resume to find. A record without the
field, written by the previous release or brought forward from schema 2, is
read as "could be either", and its conversation is resumed as before. The
previous release carries the field through its unknown fields but never sets
it. A record this release wrote as `false` therefore stays `false` past a
prompt the previous release took. A relaunch in this release then retires
that run rather than resuming it, unless this release has written the record
since.

The eighth, `transcriptPath`, is set only while a Claude run is in a turn
or waits on its question or permission prompt. It names the transcript that
the turn's `UserPromptSubmit`, the question's `PreToolUse`, or the
permission prompt's `Notification` named. Esc at either prompt, and Esc or
Ctrl+C at work, send no hook, so the app reads the stop from Claude's own
status report, or a declined wait from that transcript, and shows the turn
stopped (ADR 0004, "Work outside a turn"). The app then writes that end into
the record itself, under the record lock: `finished`, with `runStartedAt`,
`waitKind`, `tool`, and `transcriptPath` cleared, `lastHookEvent`
`wait_declined` or `interrupted`, and the episode token kept, and it ends the
turn record `interrupted` with what the transcript says the turn used. Codex
records never have the field. A record without it keeps its wait or its
work until the next hook moves it, as before, and the idle prompt a minute
later ends work the person stopped. The previous release carries the field
through its unknown fields past the turn, but this release reads the path
only for a run in a turn or one that waits, and the transcript is the same
session's, so a carried path names the right file.

### Turn records

New. Each agent's hook writes one record per turn in the provider's state
directory, `agent-states/turns/<turn-id>.turn.json` or
`codex-agent-states/turns/<turn-id>.turn.json` (schema 1). It numbers a
conversation's turns from `turns/<hash>.counter`, which only grows. In the
repository, `refs/limpid/turns/<turn-id>/begin` and `/end` pin the turn's two
snapshot trees. `docs/agent-integration-protocol.md` describes the record.

A record a newer schema wrote is read when its shape allows, and is never
rewritten or deleted. A record whose shape this build cannot read is counted
and left alone.

A record keeps who wrote its prompt in `promptKind`, an optional field of
schema 1. A record written before the field existed has none. Its kind is
judged again from `promptHead` each time it is read, and nothing is written
back. A reminder that closes within the head leaves the person's words after
it as the instruction. A prompt led by a reminder longer than the head reads
as an automatic message rather than as the person's words. A kind this build
does not know is kept as it came and written back, and reads as the person's
words; the record stays writable. A build that does not know the field keeps
it through the record's unknown fields.

Retention (`TurnRetentionLimits`, Settings → Advanced):

- A turn goes, with its refs, once it started longer ago than the days set
  (14 by default, 1 to 90), or once it is past the newest turns of its
  conversation that are kept (200 by default, 20 to 500).
- The oldest turns that may go also go once one repository's snapshots pass
  500 MB, or once more than 8,000 turns are kept in all.
- Unread turns of an open session are spared the age limit for up to 90 days.
- The latest turns of a conversation shown in a pane, the turns in a range a
  review has open or keeps comments for, and a turn read in the last 10
  minutes are kept.

The projection chooses which turns go, and `TurnGarbageCollector` deletes
each record and its refs together.

The previous release neither reads nor deletes turn records and their refs.
They stay as they are until this release runs again. The previous release's
hook records no turns meanwhile.

### `turn-reads.json` and `viewed-lines.json`

New, both `schemaVersion` 1.

`turn-reads.json` (`TurnReadStore`) keeps the turns read by having their pane
in view; a mark goes when its turn goes. Under the optional key `ends`, it
also keeps the end tree each turn was read at. A turn whose end is taken
again at another tree (the agent kept working after it stopped) becomes unread
and is read anew. A mark without an entry in `ends`, as an older build writes
it, stands for any end until the turn is next read in view, which records its
tree. An older build ignores the key and drops it when it saves.

`viewed-lines.json` (`ViewedLineStore`) keeps each conversation's viewed line,
what was viewed of the changes outside turns, and the spans of deleted turns.
Each line also moves an auxiliary ref, `refs/limpid/reviewed/<hash>`, in the
conversation's repository.

`viewed-lines.json` also keeps, under `restoreMoves`, how each applied
restore moved the viewed lines, keyed by its operation, so that Undo Restore
puts them back after a relaunch too. An entry lives as long as the restore's
journal can be undone, which has no time limit, and keeps its moves in the
line's history past its 20 entries. A restore superseded by a later turn
keeps its entry too, as its journal stays. When a whole reading of the
worktree's journals lists the restore as undone, by whatever undo, its moves
are taken back, except a move a later move of its line stands over. The entry
is dropped when that reading lists the restore as aborted, or when the reading
of its own worktree no longer lists it while the worktree is there; a worktree
Limpid cannot find (a volume not mounted) reads as one with no journal, and
its entries stay. A restore at any other stage keeps its entry. A reading that
could not read some journals settles nothing. A move also goes once it is
taken back on its own ("Unmark as Viewed"), or with its line. Each entry
records the worktree (`root`), which entries from earlier development builds
lack; those go only when a reading lists them. Each entry still records `at`:
development builds before this one cannot read the file without it, and they
drop an entry once it is 30 days old, which the file then loses when they
save. They also cut a line's history back to 20 entries at its next move,
which drops a restore's moves pushed out. A build without the key skips it,
and drops it when it saves.

Each move of a line now also carries `markID`, the mark it was made in. One
mark can move several conversations' lines: a single "Mark as Viewed up to
Here" on the worktree's timeline, the review's "Mark as Viewed" on a range
across conversations, or a restore. "Unmark as Viewed" takes back all the
moves of that mark together, whatever the panel's filter shows. Beside it,
`sequence` is the mark's place among every mark the store made, which tells
the latest mark across conversations. The moves' times cannot tell this: the
file keeps them in whole seconds, and two marks can be a moment apart. Both
keys are additive and optional. A move from a file written before them has
neither. It is taken back alone, and it counts as earlier than every move
that has a `sequence`. A build without the keys skips them and drops them
when it saves. That build then groups the moves of one mark by their time, as
it did before.

A file from a newer build is read for what it can give and not rewritten. A
file that cannot be read is dropped and written again on the next change:
turns go back to unread or not viewed, never the reverse.

The previous release does not know either file and leaves them alone.

### `stops.json`

New, `schemaVersion` 1 (`StopLedgerStore`), beside `state.json`. It holds the
stops the attention list keeps for runs that no longer report them. A run
that died at work is retired with its record, so after a relaunch this file
is the only thing that says the pane holds a conversation that stopped. A
stop stays, across launches, until the person resumes it, starts a new
conversation in its pane, or closes the pane's tabs.

The file is `{"schemaVersion": 1, "records": [...], "dismissed": [...]}`.

- Each entry of `records` holds the stop's item (`itemID`), run
  (`runtimeID`), `provider`, pane (`paneID`), `conversation`, `sessionID`,
  folder (`cwd`), turn (`turnID`), `reason`, when it stopped (`stoppedAt`),
  and whether its last resume failed (`resumeFailed`). The `reason` is told
  apart by its `kind`: `processExited`, `error` with its `message`,
  `usageLimit` with its `usageLimit`, or `notResumedAtLaunch`.
- `dismissed` lists the stops the person moved on from whose run may still
  report an error. An entry whose run no longer reports an error at the next
  look is dropped from the list.

A resume still under way at quit is written as if none were under way. The
shell it was typed into ended with the launch, so the stop offers the resume
afresh. The resumes Limpid types at launch are never written. While one
is under way, a stop of the same session in the pane says it is resuming. If
that resume fails, the launch's own stop replaces it, so a pane never holds
two stops of one conversation.

A stop whose pane the session did not restore ends at the first look. The
exception is a launch whose `state.json` could not be restored at all. No pane
came back then, through no doing of the person's, so every stop is kept, in
memory and in the file, for the launch that restores the session.

A file from a newer build is read for the stops it can give and not
rewritten. Each entry of `records` and `dismissed` is read on its own. An
entry this build cannot read (a reason a newer build added) is dropped by
itself rather than costing the whole file. It is left out at the next write
when the file is this build's version. A file that cannot be read is dropped
and written again on the next change. The last launch's stops are then lost,
and their panes stay plain shells.

The previous release does not know the file and leaves it alone. It lists no
stop after a relaunch, and the file stays as this release last wrote it.

### `ended-session-hints.json`

New, `schemaVersion` 1 (`AgentForgottenHintFile`), beside `state.json`. It
holds the resume hints of sessions the person ended ("Start New
Conversation") that Limpid could not delete yet, because a hook held the
hint's lock or the file could not be removed. Only the person knows they
moved on from a conversation. Nothing else on disk says so at the next
launch, whose rules would otherwise resume the session.

The file is `{"schemaVersion": 1, "hints": [...]}`. Each entry names the
`provider`, the pane (`pane`), and the `sessionID` the hint must still name.
A hint that a newer session has written since belongs to that pane and is
left alone. Limpid tries each hint again before every pass and at quit, keeps
it from the rules meanwhile, and removes the file once none is left. If a
write of the file fails (a folder that will not take it), the write is tried
again before every pass and at quit, even if the list has not changed since.

A file that cannot be read, or that comes from a newer build, holds no hints.
Such a session may be offered again, and the person can end it again.

The previous release does not know the file and leaves it alone. A session
ended this way may be resumed there, as it would have been before.

### `turn-deletions.json`

New, `schemaVersion` 1 (`TurnDeletionFile`), beside `state.json`. It lists
the turns that a retention batch handed to deletion and has not heard back
about. Each entry holds the turn's turns directory (`directory`), its
conversation (`conversation`), and the worktree and time it ran (`span`:
`root`, and `interval` as `start` and `duration`).

A quit can cut a deletion off after the turn's record has moved aside. The
next launch finishes the deletion before any pass has read the records, so
nothing else then knows when the turn ran. Without that span, what the turn
changed would count as changed outside turns. For each listed turn, the
launch:

- reports a turn that is gone, with its span and conversation, into
  `viewed-lines.json` and `turn-reads.json`;
- drops a turn whose record is back in place, as the next sweep decides it
  afresh;
- keeps a turn still moved aside until a batch finishes it.

The file is written before each batch goes and is removed once nothing is
listed.

A file that cannot be read, or that comes from a newer build, holds no turns.
A turn deleted unheard is then reported without its span, as before the file
was kept.

The previous release does not know the file and leaves it alone.

### `restore-pending-stops.json`

New, `schemaVersion` 1 (`RestorePendingStopFile`), beside `state.json`.
`RestoreCoordinator` writes it and reads it when it starts. It lists the
launch notices of undos that a crash cut short, whose restore or discard
could not be read when recovery settled the undo (its journal's permissions,
say). Rust names an operation as settled only in the reading that settled
it. Without the file, a notice whose operation stayed unreadable until the
app quit would never come, and for a discard that notice is the only way to
undo it.

The file is `{"schemaVersion": 1, "stops": [...]}`, written through
`VersionedListFile`. Each entry names the worktree as its journals do
(`root`), the undo recovery settled (`settledId`), the restore or discard it
was undoing (`undoableId`), and when it was settled (`since`, seconds since
2001-01-01, as `JSONEncoder` writes a date).

- An entry is added when a launch reading settles an undo cut short and
  cannot read the operation it was undoing.
- Each launch reads the listed worktrees, held by a project or not. When a
  reading lists the operation, the notice is told once, with Undo, and the
  entry goes. It also goes, untold, when the operation can no longer be
  undone, or when a whole reading leaves out the operation or the undo
  (pruned, expired, or gone).
- While the worktree's reading stays incomplete, the entry stays.
- An entry older than a journal's 30 days goes.
- Readings after a restore, discard, or undo leave the entries for the next
  launch.

The file is removed once nothing is listed. If a write fails after a notice
was told, that notice is told again at the next launch, which is safer than
losing it.

A file that is deleted, cannot be read, or comes from a newer build holds no
notices. An undo cut short whose operation is read later is then not told at
launch. A restore still offers its Undo in its record; a discard's undo is
lost.

The previous release does not know the file and leaves it alone.

### Codex's `config.toml`

Not Limpid's file: the person's own `~/.codex/config.toml`, which Codex
edits too (`CodexUserConfig`, `CodexHookInstaller`). Limpid keeps a
`[hooks.state."<key>"]` table in it for each hook it passes Codex. Each table
has two keys: `enabled = true`, and `trusted_hash`, the hash Codex compares
before it runs that hook. The key names and their format are the ones the
previous release wrote. What changed is how they are written:

- A table is ours only when its header is one Limpid would write, wherever
  it stands in the file. In it, only `enabled` and `trusted_hash` are set;
  a key Codex added to it, a comment, or a blank line stays. Everything
  else stays as it is, including a table Codex appended between our
  markers (a folder trust it recorded lands there, after the last table in
  the file). The previous release replaced the whole span between
  `# BEGIN limpid …` and `# END limpid` on every launch, which dropped
  such a table.
- A missing table goes just before `# END limpid`, or after
  `# BEGIN limpid …` when the closing marker is gone. In a file that has
  neither marker, the markers and the tables are appended at the end. The
  file is written only when something in it changes.
- A line inside a multi-line string (`"""` or `'''`) belongs to the string,
  even when it reads like one of our headers, keys, or markers.
- A file saved with CRLF line endings keeps them. Lines are compared without
  their ending, each line keeps the one it had, and a line Limpid adds takes
  the ending most of the file's lines have.
- A UTF-8 byte order mark at the start is kept.
- A `config.toml` that is a symbolic link (a dotfiles checkout) is written
  through to the file it names, so the link stays a link. A link to nothing
  is left alone, as is a file that cannot be read or is not UTF-8: read as
  empty, it would be replaced by our tables alone.

Limpid takes no copy before writing. The keys it sets are its own, and a
`trusted_hash` left from an earlier hook command would only stop Codex from
running that hook.

The previous release goes back to replacing the span between the markers
on its next launch, so a table Codex added inside it is lost again, as it
was before. It also writes in place of a symbolic link rather than through
it, appends a second block to a CRLF file (where it does not find its
markers), and replaces a file it cannot read as UTF-8 with its block alone.

### Git directories

In each repository Limpid works in:

- `refs/limpid/turns/<turn-id>/{begin,end}` (turn records, above) and
  `refs/limpid/reviewed/<hash>` (viewed lines) are new.
- Restore Code keeps a journal per operation in the worktree's
  `<git-dir>/limpid/restores/`. It pins trees with `refs/limpid/undo/<op>`
  and `refs/limpid/undo-<kind>/<op>`, and lists the refs an operation may
  hold under `<common-dir>/limpid/restore-refs/`.
  - A journal is kept 30 days once nothing can take it back. A restore that
    can still be undone is kept however old it is.
  - A journal's age is checked when Limpid reads the worktree's journals: at
    launch, and after each restore, discard, or undo there. In a worktree
    where nobody restores, a journal therefore stays past its 30 days until
    the next launch. A journal that is there but cannot be read (its
    permissions, say) is left as it is, refs and all. The others are still
    read, settled after a crash, and dropped once past their 30 days.
  - A journal records why an operation stopped short as a code (`reason`).
    For a file it could not write, it keeps that code apart from what went
    wrong (`detail`) and from where another writer's save was moved aside
    (`keptAt`). Journals from earlier development builds put that place into
    the reason (`keptAside:<place>`). They are still read, and are written
    the new way when next written. No release wrote a journal, so no
    released build reads the new form.
- `<git-dir>/limpid/turn-<pane>.index` and `turn-<pane>.end.index` are the
  private indexes the snapshots are taken through; the real index is never
  touched. The hook removes them when the session ends.
- `refs/limpid/turn/<pane>`, which the previous release moved at every prompt
  for its "This turn" review, is no longer written. When a session ends, the
  hook still removes it, along with the `turn-<pane>.read.index` that review
  wrote.

The previous release writes its per-pane ref again while it runs, and does
not touch the refs and files above.

## Going back to an earlier build

1. Quit Limpid.
2. Replace each migrated file with its copy. The copy the last migration
   started from is the one named by `backupFileName` in the file's ledger.
   - `state.json.pre-v6` (or the name in `state.json.migration.json`) to
     `state.json`
   - `settings.json.pre-v2` (or the name in `settings.json.migration.json`)
     to `settings.json`, if you want back a binding the migration moved to
     `retired`
   - `reviews/<hash>.json.pre-v2` (or the name in
     `reviews/<hash>.json.migration.json`) to `reviews/<hash>.json`, for each
     review whose comments you want in the earlier build
3. Start the earlier build.

What changed in this release after the migration is not in the copies: tabs
opened since, settings changed since, comments written since.

If a migration failed instead, the original is the `state.json.bak-*` file
from that launch. Rename it back to `state.json` the same way.

Without step 2:

- the earlier build sets the newer `state.json` aside as
  `state.json.bak-decode-failed-<unix>` and opens a fresh window; the copy is
  still there to restore later;
- it keeps reading `settings.json`, but does not read `retired`: an action
  whose ⌘⏎ binding moved there has its default keys in the earlier build, and
  a quick terminal hotkey that was on ⌘⏎ is off;
- it sets each version 2 review draft aside and starts that review empty.

Coming back to this release, `state.json` and the drafts the earlier build
wrote migrate again. A new copy (`.pre-v<N>.<unix>`) is taken when the
original changed.

- If you started the earlier build without step 2, the session this release
  saved is in the `state.json.bak-decode-failed-<unix>` file the earlier
  build left. Quit, and rename it back to `state.json` before starting this
  release. That replaces what the earlier build saved since.
- A draft the earlier build set aside as `.bak-decode-failed-` can be renamed
  back to `reviews/<hash>.json` before this release opens that review. That
  replaces any draft the earlier build wrote there since.
- From this release on, a draft from a newer build is set aside as
  `.bak-newer-version-`. It can be put back the same way once the newer build
  runs again.

Nothing else needs restoring: the earlier build ignores the new files and
fields above and keeps the ones it shares.
