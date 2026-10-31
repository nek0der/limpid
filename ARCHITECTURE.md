# Weir architecture

A one-page map of what owns what, the invariants the code depends on,
and the places we deliberately have not refactored yet. Read it
before touching `Weir/Core/Models/`, the FFI boundary, or any
persistence store. Those are the load-bearing surfaces.

For coding conventions (language, comments, lint discipline), see
[`AGENTS.md`](AGENTS.md) §3.

---

## Module map

```
Weir/
  App/           entry point (WeirApp), AppState, window controllers, menu commands
  Core/          models, settings, FFI glue, persistence, git, agents
    Domain/      plain values and pure rules (Foundation only)
  Presentation/  @MainActor @Observable stores that shape state for display
  UI/            SwiftUI views, NSViewRepresentable bridges, design system
    Supervision/ the supervision window: title bar, rails, sidebar, session area, panels
  FFI/           libghostty C ABI wrapper (GhosttyFFI)
  Resources/     Info.plist, xcstrings, claude-shim / codex-shim (sharing agent-shim/runtime-common.sh),
                 ghostty/ (shell integration, themes), terminfo
AgentIntegrationService/
  Service/        launchd-managed macOS XPC host for the Rust approval broker
  HookHelper/     the signed executable the bundled hook wrappers exec
  ProviderBridge/ Swift wrapper around the Rust provider translation C ABI
  RequesterProbe/, ControllerProbe/  development requester and controller for the two XPC roles
  Shared/         role-specific XPC contracts, identifiers, and signing policy
  Resources/      Debug and Release LaunchAgent property lists
rust/
  weir-agent-model/     portable provider-neutral events and records
  weir-agent-core/      provider-neutral lifecycle and approval rules
  weir-agent-hook/      hook runtime, record writes, and provider registry; also the
                          Git work the app calls through the bridge: restore and discard
                          (restore, restore_journal, restore_pins, restore_apply,
                          restore_write, and restore_discard), hunks, turn GC,
                          and the worktree lock
  weir-provider-claude/ Claude adapter and approval translation
  weir-provider-codex/  Codex adapter and approval translation
  weir-agent-protocol/  versioned wire messages and authenticated sessions
  weir-rust-bridge/     Rust entry points exposed through a stable C ABI
```

Swift dependencies flow from **App → UI → Presentation → Core → external
boundaries** (the layers are described below). The libghostty boundary lives
in `FFI/`. The Rust boundary lives behind `Core/Rust/WeirRustBridge.swift`
and the C header in `rust/weir-rust-bridge/include/`. Rust stays independent
of Swift and Apple frameworks. UI may consume Core models but never reaches
into their private state. Core keeps AppKit and SwiftUI out; "Layers and
dependency direction" below lists the files that predate the rule. The two
agent folders, `Core/Claude` and `Core/Codex`, never refer to each other in
code: each is independent, and the two are shaped alike.

The bridge-wide ABI number is a compatibility version, not a release or API
revision. Adding a new exported symbol keeps the current number. Increment it
only when an existing symbol's calling convention, exposed layout, ownership
contract, or documented behavior must become incompatible. Prefer a new
version-suffixed symbol, such as `_v2`, when both contracts can coexist.

The AppKit and SwiftUI imports that remain in `Core/` are listed in
`.swiftlint.yml` (`layer_ui_framework_import`).

### Layers and dependency direction

New code follows five layers. App is the composition root and may depend on
every layer. Below it, dependencies point down only:

```
App             composition root: AppState, scenes, Commands, effect performers
UI              SwiftUI views, *Representable types, the AppKit boundary
Presentation    @MainActor @Observable stores that shape state for display
Domain          plain value types and pure rules (Foundation only):
                AgentKind, AgentState, WindowID, PRState, ApprovalResolution
                (its wire form is Infrastructure's, ApprovalResolution+Wire),
                RepositoryPath, PromptWaitText, WorktreeTimeline, …
Infrastructure  persistence, git processes, XPC, notifications, GhosttyFFI,
                WeirRustBridge, and the ports they are reached through
```

Domain holds no ports. A seam (a dependency that a test or the app swaps in)
sits at the edge of the Infrastructure it stands for: `GitRunning` (`Core/Git`),
`ReviewRepositoryReading`, `ReviewDraftStoring`, and `ReviewTextDelivering`
(`Core/Review`), `ViewedLineRefWriting` (`Core/Git`), `ProjectionPassing`
(`Core/Rust`), `SurfaceViewProviding` with `ScrollbackWriting` (the terminal
behind a pane, `Core/SurfaceRegistry.swift` and
`Core/Persistence/ScrollbackFiles.swift`), and `WindowCommandPerforming`
(`Core/Actions/WindowCommand.swift`, answered by `WindowRegistry`). Some
seams are a struct of closures instead (`WorktreeChanges.Git` with `.live`
and `.inert`, `RepositoryRoots`' top level), and a few older ones are static
hooks (`CloseConfirmer.gate`, `WeirNotificationDelegate.onTap` and
`isSourceSeen`, `GhosttyActionRouter.sink`). A new seam is a protocol at the
Infrastructure edge, or a closure handed in for a single call, never a static
hook.

New Presentation code goes in `Weir/Presentation/`, new Domain code in
`Weir/Core/Domain/`, and new Infrastructure code in the rest of
`Weir/Core/`, which today still holds older display stores and AppKit
coordinators. Core never refers to a Presentation type: what a window saves is
the Core value `WindowSelection`, and Presentation adds its display-only state
on top. Domain receives facts as its own small values rather than
presentation models, and side effects travel up as values that App performs.
The Rust crates keep the rules that several processes share (the Hook Helper
and the service read and write the same files). Swift Domain keeps the rules
that need this process's facts, such as which window shows which pane.

Domain is a static module of its own, `WeirDomain` (`project.yml`), so the
compiler refuses a Domain file that names anything above it. What the layers
above read is `package`; what only Domain and its tests read stays internal, and
tests reach it with `@testable import WeirDomain`. Only the app links the
module: a test bundle that linked it too would hold a second copy of every type.
A static module has no resources, so its strings live in the app's catalog.
`scripts/check-module-strings.sh` fails the build when one is missing from it.

`make lint` enforces the part a pattern can see (`.swiftlint.yml`):

- `layer_ui_framework_import` keeps AppKit, SwiftUI, and the modules that
  carry them out of Core and Presentation. The files that predate the rule
  are listed there, each with the condition under which it leaves.
- `domain_foundation_only` and `domain_side_effect` limit Domain to
  Foundation and keep it free of `Process`, `FileManager`, and `URLSession`.
- `core_names_presentation_type` catches Core code that names the
  per-window display types or the models that word what the window shows.
- `core_names_ui_type` catches Core code that names the UI's sizes, tokens,
  and glyphs.

Design and review, not a checker, keep the type dependencies beyond that.

The files those rules let through predate them. Each leaves its list on a
stated condition:

| Rule | File | Leaves when |
|---|---|---|
| `core_names_ui_type` | `Core/CommandPalette/CommandPaletteCatalog.swift` (`ContainerSymbol`) | the symbol moves below UI, or the catalog takes a Core value the palette maps |
| `core_names_ui_type` | `Core/Models/WorkspaceSession.swift`, `WorkspaceSession+Worktree.swift` (`DropPosition`) | the drop position moves below UI, or the moves take a Core value |
| none (kept by review) | Core naming UI's `SurfaceView`: `GhosttyActionRouter`, `GhosttyEventCoordinator`, `SurfaceRegistry`, `GhosttyApp`, `SecureInputManager`, `ClipboardConfirmationCoordinator`, `GhosttyConfigBridge`, `WeirNotificationDelegate` | each reaches the terminal through `SurfaceViewProviding` or a port App implements, as the scrollback capture does (`ScrollbackWriting`, `App/SurfaceRegistry+Scrollback.swift`) |

One edge goes up rather than down: UI views read `AppState`, the composition
root, for the app's stores. The actions of the changes panel, the review tab,
and the new worktree sheet take only the stores they use:
`ChangesPanelStores`, `ReviewTabStores`, `ReviewHunkDiscardStores` (for the
review's hunk discards), and `NewSessionStores`. App builds them in
`App/AppState+ActionStores.swift`, except that the sheet builds its own from
the environment; a test builds its own. The other `*Actions` types
(`RestoreActions`, `CommitAndPRActions`, `MenuBarActions`,
`AllProjectsActions`, `SupervisionWindowActions`) still take `AppState`. Each
moves off it the same way the next time it changes.

`scripts/check-localization.sh` fails when a string to translate has no
finished Japanese translation.

---

## The supervision window

Every main window is a supervision window. No SwiftUI scene hosts one: the
app owns its windows so that closing the last one hides it rather than
ending it, and so that only Weir restores them.

- `AppState.presentSupervisionWindows` (`App/AppState+SupervisionWindows.swift`)
  hands each window to `ProjectWindowPresenter`, which makes one
  `ProjectWindowController` (an `NSWindow` with SwiftUI content) per window
  and keeps it while the window is hidden.
- `MainWindowContent` puts the window's own state in the environment
  (`ProjectWindowState`, its `ReviewPresentation`, its floating surfaces) and
  wraps the root in `WindowChromeHost`. That host lays over the root the
  overlays every window carries: toasts, the notification history, the all
  projects sheet, the keyboard shortcuts panel, the approval card, and the
  command palette dropdown. The palette, the title bar menus, the
  notification history, and the two panels over the whole window (the all
  projects sheet and the keyboard shortcuts panel) are layers, and only one
  layer is open at a time (`WindowLayer`,
  `Presentation/Window/ProjectWindowState.swift`).

The root is `UI/Supervision/SupervisionWindowView.swift`. The table lists its
parts top to bottom and left to right. View paths are under
`Weir/UI/Supervision/` unless they start with `UI/`. The display state is in
`Weir/Presentation/`, except `WorkspaceSession`, `SurfaceRegistry`,
`ReviewSession`, and `WorktreeTimeline`, which are in Core:

| Part | View | Display state |
|---|---|---|
| Title bar: project ▾, worktree ▾, back and forward, palette field, Needs Attention n | `TitleBar/SupervisionTitleBar.swift`, `TitleBarHistoryButtons`, `NeedsAttentionPill`, `NeedsAttentionListView`, `TitleBarMenuHost` | `ProjectMenuModel`, `WorktreeDropdownEntry`, `TitleBarHistoryModel`, `NeedsAttentionPillModel`, `NeedsAttentionListModel` |
| Left rail: worktrees, all projects, history; update, plan usage, shortcuts, Settings | `LeftRail/LeftRailView.swift` | `ProjectWindowState` |
| Plan usage panel: each agent's limit windows, a floating panel beside the rail like the notification history (`WindowLayer.planUsage`) | `LeftRail/PlanUsagePanel.swift` | `PlanUsageStore` and `PlanUsageText` (Claude Code's from the status line relay's record, `PlanUsageRecordDirectory`; Codex's from its app server, `CodexUsageReader`) |
| Sidebar: every project under its header (folded or open, in the window's order), each open one's working rows and the folds for the missing worktrees, the worktrees ready to clean up, and the other worktrees, then the scratch row | `Sidebar/SessionSidebarView.swift`, `SidebarProjectSection`, `SidebarProjectReorderLayer`, `SidebarProjectHeaderView`, `SidebarProjectActions`, `SessionRowView`, `SidebarSectionFoldRow`, `SidebarRowDrop` | `SidebarListModel`, `SidebarProjectHeader`, `SidebarProjectDrag`, `SidebarPinnedLine`, `SessionSidebarModel`, `SidebarPresentedSections`, `SidebarKeyboardCursor`, `SidebarKeyRoute`, `SidebarArrangement`, `ProjectOrder`, `SidebarSectionRule`, `SidebarSectionHold`, `RowName` |
| Session area: header, pane strip and its Open Tabs list, terminal | `SessionAreaView.swift`, `PaneStrip/SessionHeaderView.swift`, `PaneStrip/PaneStripView.swift`, `PaneStrip/OpenTabsMenu.swift`, `SessionTerminalView.swift` | `SessionHeaderModel`, `PaneStripModel`, `AgentBadgeSlots`, `OpenTabsModel`, `ConversationTabs`, `ConversationIdentityStore` |
| Panes and splits inside the terminal region, and the frame a hovered turn card puts around its pane | `UI/Pane/PaneAreaView.swift`, `PaneContainerView`, `PaneHostView`, `PaneStrip/PaneConversationFrame.swift` | `WorkspaceSession`, `SurfaceRegistry`, `ConversationHoverRule` |
| Decision bar under each agent pane | `DecisionBar/DecisionBarView.swift` (placed by `PaneContainerView`) | `DecisionBarModel` |
| Review tab, drawn where the terminal was, with its one scope menu (the worktree's unviewed turns, each conversation's, the worktree's own comparisons) | `ReviewTab/ReviewTabView.swift` (placed by `PaneAreaView`), `ReviewTab/ReviewTabScopeMenu.swift` | `ReviewTabModel`, `ReviewScopeMenu`, `ReviewFileTags`, `ReviewSession`, `WorktreeTimeline`, `ConversationChoice` |
| Changes panel (the worktree's turns as one timeline, filtered by conversation) and the right rail | `Changes/ChangesPanelView.swift`, `RightRail/RightRailView.swift` | `ChangesPanelModel`, `WorktreeTimeline`, `ConversationChoice`, `ConversationTabs`, `ConversationIdentityStore`, `ConversationHoverPresentation`, `ChangesPanelLayoutRule`, `CommitAndPRModel` |
| Status band along the bottom | `StatusBand/StatusBandView.swift` | `StatusBandModel` |
| A window that shows nothing yet | `EmptyWindowView.swift` | `EmptyWindowModel` |

Three more parts sit over the window. The window's root presents the new
worktree sheet (`NewWorktreeSheetHost.swift`, `NewSession/NewSessionSheet.swift`,
`NewSessionModel`), whatever the window shows; `NewWorktreeSheetSlot` keeps a
request that could not come up from blocking the next or opening later.
`NewSessionActions` holds what the sheet reads as it opens, its fetch, what
"Create" makes, and ⌥⌘N, which makes the same form at once
(`InstantWorktreePlan`). `WindowChromeHost` lays the all projects sheet
(`AllProjects/AllProjectsOverlay.swift`, `AllProjectsModel`) and the approval
card (`UI/ApprovalCardHost.swift`, `ApprovalCardModel`).

Outside every window is the menu bar extra
(`MenuBar/SupervisionMenuBar.swift`, `MenuBarModel`), a scene of `WeirApp`.
It draws the Needs Attention list's rows with the list's own
`Attention/NeedsAttentionRowView.swift`. Its icon (`MenuBarLabelModel`) is a
lamp that shows the attention state but no count: the app's mark alone, the
mark with a dot at its corner for unread turns, or with an exclamation mark
there when something is blocked on the person, all in the menu bar's own ink.

A view reads its model. A `+Session` extension beside the model builds it
from the session, the attention list, and the window
(`SessionSidebarModel+Session.swift`, `DecisionBarModel+Session.swift`, …),
so the rules can be tested without drawing anything. What a button does lives
in an `*Actions` type beside the view (`ChangesPanelActions`,
`ReviewTabActions`, `SupervisionWindowActions`), which is handed the stores it
uses (see "Layers and dependency direction").

### Per-window state and the shared session

`WorkspaceSession` (`Core/Models/WorkspaceSession.swift`) is shared by every
window: the projects with their worktrees, the flat tab list, the agents and
terminals behind the tabs. It is not one sidebar row. A sidebar row is one
worktree (the project's own folder is the main one), derived from the
session; the type names keep "session" (`SessionSidebarModel`,
`SessionRowView`) from before the rows were called worktrees.

The sidebar, the worktree ▾, the project ▾, the palette's "#", ⌃⌘1…9, ⌘[ ⌘],
and the all projects sheet list projects and rows in one order and name rows
by one rule. The projects come in the window's `SidebarArrangement`; a
project's rows come in the sections its sidebar shows them
(`SidebarPresentedSections.ordered`: the folder, the working worktrees, then
the folded sections); a row goes by `RowName`. Only the all projects sheet
re-sorts, by state, which is what it is for: the sidebar never reorders
itself. Core cannot name the presented sections, so the palette is
handed their order (`SupervisionPaletteFacts.rowOrder`).

Each window has two objects of its own:

- `WindowSelection` (Core) is what the window has selected and how it is laid
  out: its project, container, and tab, the sidebar's width and its
  arrangement (`SidebarArrangement`: the projects' order, the folded
  headers, the open sections), the changes panel. The sidebar and the
  panel are the window's chrome, and they stay as the window switches
  projects; only the header of the project switched to opens. The session keeps one selection per
  window (`WorkspaceSession.selections`). The primary window's selection is
  `primarySelection`; the primary role passes to another window as windows
  close. A selection is saved as a `WindowRecord`
  (`Core/Persistence/WindowRecord.swift`) in `state.json`'s `windows`.
- `ProjectWindowState` (Presentation) is what the window shows that is never
  saved: its ⌘J cursor, the decision bar's choice per pane, the open review
  tab, its panels and dropdowns, and the sections its sidebar shows every
  project's rows in (`presentedSections`), which the pointer, the keyboard,
  or a drag holds so a row does not move under the person; ⌃⌘1…9 and ⌘[ ⌘] count
  the same rows (`AppState.sidebarSections(in:)`). It holds its
  `WindowSelection` rather than looking it up.

`WindowRegistry` (`Presentation/Window/WindowRegistry.swift`) lists the
windows and names the one commands act on. A menu command goes to
`commandTarget`, the main window AppKit reports as key. Anything with no
keyboard to read (a toast, a notification, the menu bar extra) goes to
`backgroundCommandTarget`, the window that last had the keyboard. The
registry also keeps what a project left behind while no window shows it: its
review (`ParkedReview`) and where its lists were scrolled. The session keeps
the project's selection (`projectViews`), which does not include the
window's chrome.

A window shows one project at a time, and a project is shown in one window at
a time. Choosing another project switches the window in place, or brings
forward the window that already shows it (`connectProjectSwitching`). New
windows are made only when asked for (New Window, or a ⌘-click). The scratch
tabs belong to no project and draw in one window at a time
(`WorkspaceSession.scratchOwnerWindowID`, `scratchDrawingWindowID`,
`claimScratch(for:)`).

Every write of a window's selection names why it is made
(`SelectionIntent`, `Core/Models/SelectionIntent.swift`). Only the person's
own choice brings a window forward, takes it to another project, or moves the
scratch tabs to it. What a project showed when a window last left it is a
`ProjectView` (`Core/Models/ProjectView.swift`), kept in
`WorkspaceSession.projectViews` and put back when a window shows the project
again. A pane area reports which panes it shows through its window's
`PaneVisibilityReporter`. The registry joins every window's report before it
puts terminals to sleep, so one window never puts to sleep a terminal that
another window shows.

A command asked of one window by the menus, the palette, the keyboard
shortcuts, or the window's own rails is a `WindowCommand`
(`Core/Actions/WindowCommand.swift`), delivered through
`WindowRegistry.perform(_:in:)` to that window's `ProjectWindowState.commands`
(`WindowCommandChannel`). The view that carries a command out takes it
(`View.onWindowCommand`). A command that no view took, or that names a window
no longer open, is logged and reported as not run. `NotificationCenter`
carries only what does not belong to one window: `weirOpenSettings` (the app's one Settings
scene), `weirCommandPaletteFocus` (one palette is open at a time),
`weirSearchFocus` (addressed to a pane), and `weirGitSyncRequested`
(addressed to a project, for `GitSyncCoordinator`).

Two stores ask Git about a worktree once and share the answer with every
window and view. `RepositoryRoots` (`Presentation/Window`) keeps each session
folder's Git top level and matches a turn's recorded root to it.
`WorktreeChanges` (`Presentation/Window`) keeps three things the changes panel
and the review tab share: what the worktree's turns do not account for, the
totals of its unviewed range, and the files each turn changed. Two Core
stores sit beside them. `GitFactsStore` (`Core/Git`) keeps each folder's
commits and uncommitted files for the session header, the sidebar, and the
changes panel. `SessionLaunchStore` (`Core/Models`) tracks a new worktree
between its making and what it opens: the ignored files being copied
(`IgnoredFileSelection` in Domain, `IgnoredFileCopier` off the main actor),
the setup that is running, the stage that failed, or the notes left.

### Attention, turns, and approvals

The agents' hooks write run records and turn records. The Rust projection
reads them on each pass (`AgentProjectionAdapter`) and returns the runtimes,
the turns, and the commands for the app to perform.

- **Runtimes** go to `AttentionState` (`Core/Attention/`), which keeps each
  agent run's badge and which finished runs were seen.
- **Turns** go to `TurnHistory` (`Core/Agent/TurnHistory.swift`), by
  conversation. `TurnRecordCache` sends each record's content to the
  projection only when its file changed.
- **Unread** is decided in Domain from the turns and two stores.
  `TurnReadRules` marks a turn that changed no files as read once its pane
  is in sight, and `TurnReadStore` keeps those reads in `turn-reads.json`. A
  turn that changed files stays unread until the viewed line passes it
  (`ViewedLine`, kept by `ViewedLineStore` in `viewed-lines.json`, with an
  auxiliary ref `refs/weir/reviewed/<hash>` per conversation). Each
  conversation keeps its own line. The turns of every conversation in a
  worktree form one timeline, `WorktreeTimeline` (`Core/Domain`), built from
  `TurnHistory` alone. It holds their order by `startedAt`, the turn that
  ended last, the turns of a range, and the turns a line moves to. The
  changes panel (`ChangesPanelModel`) marks each row against its own
  conversation's line. It and the review (`ReviewScopeCatalog`,
  `ReviewTurnRange`, `ReviewHunkDiscardRules`) read that one type, so they
  never disagree on what comes after what. Both name a conversation, and
  sort a menu of conversations, with `ConversationChoice`
  (`Presentation/Conversation`). `UnreadTurnRules` builds the unread items
  from the two stores. Every surface reads a conversation's identity color
  from one store, `ConversationIdentityStore`, which works the colors out
  again only when the turns, the lines, the running set, the restored
  turns, or the path spellings change, and reads which tab runs which
  conversation from one mapping, `ConversationTabs`.
- **Approvals.** The signed Hook Helper submits a request to the Agent
  Integration Service (`docs/agent-integration-protocol.md`).
  `ApprovalPresentationStore` (`Core/Agent/ApprovalPresentationStore.swift`)
  subscribes to the broker as its controller, through the exchanges in
  `ApprovalControllerConnection`, and holds what it sees. Its
  `ApprovalLedger` keeps each request after it leaves the pending list,
  until its turn is over. A request whose pane is in sight goes straight to
  the agent's own prompt. A request whose pane is out of sight is held for
  the approval card. `handOffSeenRequests` makes that split;
  `AppState+AgentIntegration.swift` runs it, and
  `AttentionVisibility.allowsHandOff` decides each request. Each window has its own card, with the frames of the sidebar
  rows it stands beside (`WindowApprovalCard`, `Presentation/Approval`, held
  by `ProjectWindowState.approvalCard`). The requests, the ledger, and the
  unsent answers are shared, and every window's card follows them as they
  settle (`ApprovalPresentationStore.onRequestsChanged`,
  `WindowRegistry.settleApprovalCards`). The menu bar may allow or deny only
  what `MenuBarApprovalRule` permits. The service starts only in a build
  signed with a Team ID (`AgentIntegrationServiceRegistrar`). An ad-hoc
  signed build leaves every approval to the agent's own prompt.
- **The attention list** is `AttentionQueueStore`
  (`Presentation/Attention/AttentionQueueStore.swift`). There is one for the
  app, and it is never saved. `AttentionQueueReducer` rebuilds it from the
  runtimes with their unread turns, the ledger's requests, the stops
  (`StopLedgerStore`), the new worktrees whose agent did not start, and what
  the windows show. Items keep the order they arrived in. ⌘J walks the list
  from a window's cursor. The Needs Attention list, the sidebar rows, the
  decision bars, the menu bar, and the Dock badge read it.
- **Retention.** `AppState+TurnRetention.swift` tells the projection which
  turns a person may still need (`TurnProtection`). The projection's sweep
  returns `deleteTurn` commands, and `TurnGarbageCollector` deletes each
  record with its refs through `WeirTurnBridge`. The limits come from
  `TurnRetentionLimits` and Settings → Advanced, which asks first when a
  narrower limit would delete records, with the count the sweep itself
  makes without deleting (`weir_projection_engine_turns_taken_v1`).
- **A turn the person stopped.** Claude sends no hook when the person
  declines its question or permission prompt, with Esc or with "No", nor
  when they stop its work with Esc or Ctrl+C. Claude does report its status
  to the terminal over OSC 7501, which libghostty forwards
  (`GHOSTTY_ACTION_PROGRAM_STATUS`) and `PaneProgramStatusStore` keeps per
  pane; it also leaves the titles Claude writes meanwhile off the tab. The
  projection reads the stop from an idle report in the run's pane made
  after the record last changed, and a declined wait otherwise from the
  transcript the run record names, and its badge shows the turn stopped at
  once (`waitDeclined` or `interrupted`). The same pass returns an
  `endStoppedTurn` command, and `StoppedTurnCloser` hands it to Rust
  (`WeirTurnBridge.endStoppedTurn`), off the main actor: once when the
  write settles, and up to three times for a write that does not. Under the
  record lock, Rust ends the run record and its turn as the hook's idle
  prompt would, with what the transcript says the turn used, so the Changes
  panel and a restore read the turn as stopped too. The decision bar then
  says a wait was declined, not answered.
- **A wait only the agent reports.** An MCP server's request for input
  under Codex, a Codex question left open after its turn, and a sign-in send
  no hook. (Claude Code announces an MCP server's request with its
  `Elicitation` hook, and its `ElicitationResult` ends the wait.) Both
  agents report them over OSC 7501 as `blocked` with a kind (`question`,
  `auth`), which `PaneProgramStatusStore` keeps with the state. The
  projection shows the run waiting on a question or a sign-in until the next
  report, without writing its record, and leaves a wait a hook announced as
  it is. A sign-in reads "Needs sign-in" in the row, the list, the decision
  bar, and the notification, and is counted on its own.
- **Restore Code** ("Restore Code to Before This Turn…" on a changes panel
  row and in the decision bar's ⋯ menu) runs through `RestoreCoordinator` into
  Rust (`WeirRestoreBridge`). Rust journals each operation under the
  worktree's `<git-dir>/weir/restores/` and pins the trees it may need with
  `refs/weir/undo*/<op>`. `AppState+Restore.swift` asks `RestoreGate`
  whether a restore may run, and recovers a restore that a quit cut short.
  An undo cut short whose restore or discard cannot be read yet keeps its
  launch notice in `restore-pending-stops.json` (`RestorePendingStopFile`)
  until a later launch reads that operation.

### Restoring the session at launch

`AppState` loads `state.json` through `SessionStore`, migrating it first
(`docs/data-migration.md`). It then calls `WorkspaceSession.restore(from:)`,
which rebuilds the projects, the tabs, and one selection per saved
`WindowRecord`. `WindowRegistry.adoptWindows(of:)` lists the windows before
anything can ask for one, and `showRestoredWindows(of:)` shows them. The
window the person was last in is shown last, so it ends up in front. Each
tab's scrollback comes back from its
`.vt` file in the folder the app hands the session (`ScrollbackFiles`,
`WorkspaceSession+Scrollback.swift`), and an agent pane starts its
conversation again as its surface mounts (`AgentResumeCommandBuilder`).

---

## Load-bearing files

| File | Owns |
|---|---|
| `Weir/App/WeirApp.swift` | Scene tree, command menu, and `AppState` — the process-wide singleton holding the session, the window registry, the stores, and the agent projection adapter |
| `Weir/App/ProjectWindowPresenter.swift` + `ProjectWindowController.swift` | The app-owned main windows: made, shown, hidden, and closed through the registry |
| `Weir/UI/Supervision/SupervisionWindowView.swift` | The supervision window's root: title bar, rails, sidebar, session area, changes panel, status band |
| `Weir/Core/Models/WorkspaceSession.swift` | Projects, worktrees, tabs, and every window's selection, shared by all windows; the source of truth |
| `Weir/Core/Models/WindowSelection.swift` | What one window has selected and how it is laid out (saved as `WindowRecord`) |
| `Weir/Presentation/Window/WindowRegistry.swift` + `ProjectWindowState.swift` | The windows, which one commands act on, and each window's unsaved display state |
| `Weir/Core/Models/Tab.swift` + `SplitTree.swift` | Per-tab structure (kind, working directory, split tree, agent sessions) and `ContainerID` |
| `Weir/Core/Persistence/SessionSnapshot.swift` | The on-disk shape of `state.json`, with its forward-compatible sidecar |
| `Weir/Core/Persistence/SessionSnapshotV5.swift` + `VersionedDocumentMigrator.swift` + `MigrationBackup.swift` | Moving saved files between versions, with a copy of the original (`docs/data-migration.md`) |
| `Weir/Presentation/Attention/AttentionQueueStore.swift` | The app's one attention list: ⌘J, Needs Attention, the decision bars, the menu bar |
| `Weir/Core/Agent/ApprovalPresentationStore.swift` + `ApprovalLedger.swift` | The approval service's requests as the app holds them, and how each request ended |
| `Weir/Presentation/Approval/WindowApprovalCard.swift` | One window's approval card and the frames of the request rows it stands beside |
| `Weir/Core/Actions/WindowCommand.swift` + `Presentation/Window/WindowCommandChannel.swift` | What one window is asked to do, and its delivery to the view of that window that does it |
| `Weir/Core/Agent/TurnHistory.swift` | Every recorded turn, by conversation, as the last projection pass read them |
| `Weir/Core/Domain/WorktreeTimeline.swift` | Every conversation's turns of a worktree as one timeline, which the changes panel and the review read |
| `Weir/Core/Rust/WeirProjectionBridge.swift` | The projection pass over the records, through the Rust bridge (`ProjectionPassing`) |
| `Weir/Presentation/Window/RepositoryRoots.swift` + `WorktreeChanges.swift` | Each folder's Git top level, and what each worktree's turns changed and do not account for |
| `Weir/Presentation/Review/ReviewTabModel.swift` | `ReviewTabState`, what one window's review tab reads, and the rules that open, change, and close it |
| `Weir/Core/Persistence/TurnReadStore.swift` + `ViewedLineStore.swift` | Which turns are read, and how far each conversation has been viewed |
| `Weir/Core/Settings/WeirSettings.swift` | The settings model and its section structs, all `Codable` |
| `Weir/Core/Settings/GhosttyConfigBridge.swift` | Generates the libghostty config string and the forced-override keys |
| `Weir/Core/GhosttyApp.swift` | Wraps `ghostty_app_t`, runtime callbacks, lifecycle |
| `Weir/Core/Rust/WeirRustBridge.swift` | The typed Swift entry point for the versioned Rust C ABI |
| `Weir/Core/Agent/AgentIntegrationServiceRegistrar.swift` | Registering, verifying, and replacing the bundled LaunchAgent on launch, plus the Debug-only `WEIR_AGENT_SERVICE_CONTROL` commands |
| `AgentIntegrationService/Service/main.swift` | Role-separated XPC listeners and authenticated principal creation |
| `AgentIntegrationService/Service/RustApprovalHost.swift` | Ownership-safe Swift wrapper around the Rust approval service and session C ABI |
| `AgentIntegrationService/Shared/AgentIntegrationConfiguration.swift` | Debug/Release identifiers and Team ID-bound peer requirements |
| `scripts/build-rust-bridge.sh` | Builds the architecture-specific Rust static library into Xcode DerivedData |
| `Weir/Core/SurfaceRegistry.swift` | The `[UUID: SurfaceView]` map that owns the lifetime of every pane's surface (the quick terminal's surface lives outside it) |
| `Weir/UI/QuickTerminal/QuickTerminalController.swift` | The quick terminal panel: show / hide choreography, activation hand-back, and the lifetime of its one surface outside the registry |
| `Weir/Core/QuickTerminal/QuickTerminalHotKeyCenter.swift` | Keeps the quick terminal's global hotkey registered to match the setting, the keyboard layout, and the Settings recorders |
| `Weir/UI/SurfaceView.swift` | The `NSView` subclass that owns the libghostty surface and its Metal layer |
| `Weir/UI/Pane/PaneHostView.swift` | The `NSViewRepresentable` that bridges `SurfaceRegistry` and `SplitTree` |
| `Weir/Core/Git/PRStatusSyncer.swift` | Schedules forge CLI lookups per sidebar row, at each row's own interval and as an agent's turn ends there (`TurnEndPRRefresh`), and writes them into `PRStatusStore` (no setting; whatever `gh` / `glab` can read) |
| `Weir/Core/Review/ReviewSession.swift` | One view's review: its scope, list and open diff, and the comment lifecycle (written → inserted → resolved) |
| `Weir/Core/Review/ReviewDraftWriter.swift` | The draft one worktree's reviews share: comments, read marks, and the file it restores from |
| `Weir/Core/Review/ReviewGitCommand.swift` | Every Git read the review makes, and the patch bytes both the change poll and the diff hash |
| `Weir/Core/Git/ProcessDrain.swift` | The one runner of a bounded child process: its pipes read while it runs, its timeout, its output cap, SIGTERM then SIGKILL (`GitProcess`, the forge tools, the review's Git, the tmux client) |
| `Weir/Core/Actions/ReviewInsertion.swift` | The order an insert happens in: resolve the pane, validate, deliver, then record |
| `Weir/Core/Review/ReviewPresentation.swift` | Where review sits in a window, and which terminal it delivers to — following the focused pane until the reader pins one |
| `Weir/Core/Updates/SparkleUpdater.swift` | Sparkle integration: the one `@Observable` updater the app and Settings share |

---

## Invariants

### Active-selection invariant

For each window, when its `WindowSelection.activeTabID` is non-nil,
`tabs.first(where: { $0.id == activeTabID })?.container` equals the
selection's `activeContainerID`. Two methods maintain it:
`WorkspaceSession.setActiveTab(_:in:intent:)` mirrors the tab's
container, and `setActiveContainer(_:in:intent:)` clears `activeTabID`
when the container is empty and otherwise routes through `setActiveTab`.
The invariant may break briefly, and legitimately, in `init`,
`restore(from:)`, and the close paths (`closeTab` / `closeTabs(where:)`)
that clear `activeTabID` before the caller picks the next container.

### SurfaceView lifetime

`SurfaceRegistry` holds the `SurfaceView` instances, keyed by
`SplitTree` leaf UUID. SwiftUI rebuilds the surrounding view tree on
tab switches, on project switches, and when the review tab takes the
terminal's place. The registry's strong reference keeps the surface alive
across those rebuilds. Only destructive operations (closing a tab,
removing a worktree, the surface-exit callback) call
`registry.unregister(_:)` and `registry.reconcile(activeIDs:)`. Tab
switches never do.

The quick terminal's one surface is the exception. It is not in the
registry, whose reconcile and occlusion passes only know about panes.
`QuickTerminalController` owns it, and its close and child-exit events
reach the controller before `GhosttyEventCoordinator` looks the surface up
in the registry.

The libghostty handle (`ghostty_surface_t`) is freed exactly once,
in `SurfaceView.deinit`. The deinit hops to the MainActor through
`Task { @MainActor in ghostty_surface_free(s) }` because Swift 6
can run a deinit on any thread.

`SurfaceView.viewDidMoveToWindow` calls `createSurface()` only when
`window != nil`. If AppKit lands the first `viewDidMoveToWindow` with
a nil window (a split race, a divider drag),
`PaneHostRepresentable.updateNSView` (`UI/Pane/PaneHostView.swift`)
recovers by retrying `createSurface()` the next time SwiftUI updates it.

### FFI userdata

C callbacks from libghostty pass `UnsafeRawPointer` userdata that
points at a `SurfaceView`. The `SurfaceView` may have been deinitialized
between the callback firing on libghostty's thread and the hop to the
MainActor. `SurfaceView.liveView(forUserdata:)` resolves the pointer
through a weak registry, so a freed view comes back as nil instead of
being dereferenced in freed memory.

### Rust ABI boundary

Swift imports Rust only through the C declarations in
`rust/weir-rust-bridge/include/`. Exported functions use fixed-width C types,
and `weir_rust_abi_version()` is the compatibility contract checked by the
Swift smoke test. Do not expose Rust layout, ownership, or panic behavior
across this boundary.

The approval host owns one opaque Rust service handle and creates one opaque
session handle per authenticated XPC connection. XPC preserves discrete
`Data` message boundaries, so the bridge exchanges one bounded JSON request
and one allocated JSON response per call rather than reusing the stream
framing adapter. Swift always releases response bytes through the matching
Rust free function. The requester run ID is generated by the host and passed
as fixed 16-byte UUID data; it is never accepted as a claim of authority from
the JSON payload.

Xcode invokes `scripts/build-rust-bridge.sh` on every app build and lets Cargo
own the fine-grained Rust dependency graph. The script places Cargo output in
DerivedData and replaces the linked static library only when its contents
change. A new Rust module is therefore never missed, and unchanged Swift
targets are not forced to relink.

### Forced-override Ghostty config keys

`GhosttyConfigBridge` always emits a fixed set of keys, regardless of
user settings:

- `background-opacity=0`
- `term`: `xterm-ghostty` when the bundled terminfo is present, else
  `xterm-256color`
- `shell-integration-features=no-cursor,sudo,ssh-env`
- `confirm-close-surface=false`
- `custom-shader-animation=false`
- `clipboard-paste-protection=true`
- three forced `keybind=` lines

Most of them protect the UI compositor and the rendering path, and
removing one silently breaks the app. `clipboard-paste-protection` is
there for a different reason: it keeps a shell from running the lines a
review pastes as commands. See the forced-overrides comment block in
`GhosttyConfigBridge.makeConfigString`.

### Persistence

The top-level stores (`SessionStore`, `SettingsStore`,
`NotificationHistoryStore`, `FrecencyStore`, `TurnReadStore`,
`ViewedLineStore`, `StopLedgerStore`, and the review's
`FileReviewDraftStore`) decode through `PersistenceCoders.makeDecoder()`
so their JSON shapes stay consistent, and debounce with
`PersistenceTiming.interactive` / `.coalescing`. All but `SettingsStore`
encode with `PersistenceCoders.makeEncoder()`. `SettingsStore` encodes
with `WeirSettings.makeFileEncoder()`, which always pretty-prints,
because `settings.json` is the one file the user is expected to open in
an editor. The review coalesces its navigation metadata on a serial write
queue, but a comment edit waits for storage, so a failed save keeps the
composer open. A versioned file is read through
`VersionedDocumentMigrator`, which brings an older one forward after
`MigrationBackup` has copied it; `docs/data-migration.md` has every file this
covers and how to go back.

### Turn review snapshots

At `UserPromptSubmit`, each agent hook copies the worktree's real index into
`<git-dir>/weir/turn-<pane>.index`, runs `git add -A` against that private
index, and writes its tree. The private index is separate from the real one;
user staging state and `git status` remain untouched.

That snapshot begins a turn record. At the end of the turn (`Stop`, a
failure, or an interrupt the provider reports) the hook takes a second
snapshot in the repository the turn began in, through
`turn-<pane>.end.index`, and writes what changed between the two trees to
`<state>/turns/<turn-id>.turn.json`, with the tokens the turn used as the
agent's transcript records them (and, for Codex, the checks it ran). A stop that follows work another stop
hook asked for (`stop_hook_active`) takes the end again, since the turn went
on; any other stop of an ended turn, or an end with no turn, writes an
end-only record that reads as incomplete. Each tree is pinned by
`refs/weir/turns/<turn-id>/{begin,end}`. These refs keep the otherwise
unreachable trees out of Git's garbage collection without adding a commit or
changing history. They outlive the session: they go with the turn, not with
the pane. A
conversation's turns are numbered from `<state>/turns/<hash>.counter`, which
only grows, so a deleted turn's number is never given again. Untracked files
over 5 MiB are left out of both trees and listed on the record.

Earlier builds also moved a per-pane `refs/weir/turn/<pane>` at every
prompt for a "This turn" review scope. Nothing writes that ref now. When a
session ends, the hook still removes it, along with the
`turn-<pane>.read.index` that review wrote, so repositories those builds left
them in are cleaned up.

The review tab reads turns through their records. A fixed range compares the
begin tree of its first turn with the end tree of its last
(`ReviewScope.turns`), so later prompts and edits do not change what it
shows. The worktree's unviewed turns are one such range across
conversations. It runs from the begin tree of the oldest unviewed turn to the
end tree of the turn that ended last, and a turn still running leaves it
incomplete. The range is built from the same timeline the changes panel lists
(`TurnHistory`, never the records on disk). A scope request is refused while
the composer contains unsaved text: the reader must save or cancel it before
the loaded diff can change.

Agent lifecycle stores are runtime-scoped: one UUID per shim invocation, plus
tmux socket, server-generation, and pane metadata when a multiplexer sits
between the agent and Weir. Hooks never query tmux. `TmuxTopology` resolves
current pane membership (including linked windows), and `TmuxPanePresence`
joins clients to surface ttys. An unresolved tmux record never falls back to a
launch pane or a saved restore binding. What runs in front of a pane is read in
one place, `ProcessNames` (`Core/Process`), by the path the process was started
from, so a long executable name is never cut to the kernel's 16 characters.
The terminal, the review's paste probe, and `TmuxPaneJob` (which asks the
person's own tmux what its active pane runs) all use it.
`PaneForegroundWiring` decides which of these readings a resume's deadline and
the launch tracking get. `AgentRuntimePresentation` keeps each invocation
through notification and Attention processing; badges are only the final
reduction. Native resume hints remain pane-scoped but carry the owning run ID,
and tmux hooks do not overwrite them. Cwd event stores also remain
pane-scoped. These agent stores keep their own, tighter configuration, because
they write tiny records on the hot path and several hooks can be in flight at
once.

The Rust hook runtime inside the signed Hook Helper
(`hook <provider> [worktree]`) writes the records; the bundled `weir-hook`
wrappers exec it. It is the only receiver. A wrapper that finds no helper says
so on stderr and in the system log and fails the call, and the app logs a
fault at launch. Neither records the run some other way that would write no
turns. Writers coordinate on each record's `.flock` sidecar: the Rust runtime
takes it with `File::try_lock` and the app with `AgentFileLock`. Both are
`flock(2)` on the same sidecar inode, so they exclude each other.

Where an intercepted `git worktree add` lands is read from
`worktree-routing.json`. The one save path (`SessionStore.writeSnapshot`)
writes it beside `state.json`, so the hook's view of the projects is updated
from a single place. The two files are separate atomic writes. A routing
write that fails is logged and leaves the hook on the rule it read last, so
the two files can be one save apart.

Forward-compatible persistence:

- Defensive `init(from:)` for every `Codable` enum with an
  `unknownFallback` case (`Tab.Kind`, `ConfirmPolicy`, `ContainerID`)
- `WeirJSONValue` sidecar carrying unknown fields through round
  trips (`SessionSnapshot` with its `Tab`, `Project`, and `Worktree`,
  `WeirSettings` and section structs). Other nested records do not keep
  unknown keys; `docs/data-migration.md` says which and why
- `tabs: {UUID: Tab}` + `tabOrder: [UUID]` shape on `SessionSnapshot`
  so a reorder doesn't churn the whole tab block
- `[.sortedKeys]` everywhere for clean diffs

---

## How to add X

Quick pointers. We keep the touch points deliberately concentrated so
`grep` finds them. Thanks to the defensive `Codable` decoders, an older
build that reads a newer file degrades cleanly.

- **New `Tab.Kind`** — add a case in `Tab.swift` (the decoder routes an
  unknown kind to `.terminal`). Branch in `PaneAreaView` /
  `SessionTerminalView` if it doesn't render as a terminal.
- **New container kind** — add a case to `ContainerID` in `Tab.swift` (the
  decoder folds an unknown one to `.loose`, the scratch tabs). The
  compiler lists the `switch`es that must take it:
  `WorkspaceSession.{containerExists, containerLabel, lastActiveTabID,
  rememberLastActive, forgetLastActive}`, `WorkspaceSession+Tabs.{openTab,
  rootDirectory(of:), tabs(in:)}`, and `WindowTitleText`. A kind that is
  saved needs a `Container` case in `SessionSnapshot.swift` (an unknown
  kind is passed over on decode) and a row in `SessionSidebarModel`; extend
  `SessionSnapshotTests` and `WorkspaceSessionFixture`.
- **New Ghostty event** — wire the callback in `GhosttyApp.swift`
  (following the `wakeupCallback` pattern), add a case to `GhosttyEvent` in
  `GhosttyActionRouter.swift` and decode it there, then handle it in
  `GhosttyEventCoordinator.dispatch(_:)`.
- **New settings section** — add a `Codable` struct in
  `WeirSettings.swift` with `unknownFields` and `CodingKeys: CaseIterable`,
  add its property to `WeirSettings`, put its pane in
  `UI/Settings/Panes/`, register the pane in `SettingsScene`, and add every
  searchable row to `SettingsSearchCatalog` with the same stable anchor ID
  its view uses.
- **New keyboard shortcut** — add a case to `WeirShortcutAction` (five
  compiler-enforced spots: `defaultShortcut`, `localizedTitle`,
  `category`, `iconName`, `ghosttyAction`), a menu bar `Button` in the
  `Commands` type of its menu (`App/TabCommands.swift`,
  `App/SupervisionCommands.swift`, …, listed in `WeirApp`'s `.commands`),
  and a case in `TabActions.dispatch<Category>Action`.
- **New agent CLI** — add a provider crate at
  `rust/weir-provider-<agent>/` (descriptor, install recipe, `normalize`),
  recorded fixtures under `rust/fixtures/<agent>/`, and an adapter entry in the
  hook's provider registry. The application projection (`project`, `on_launch`,
  `on_terminate`) runs in Rust and branches on capabilities, so the rules need
  no change. The Swift side still keys the interface by `AgentKind`: add a
  case there, an `AgentSpec` conformer in `Core/Agent/<Agent>Agent.swift` for
  the resume command, a shim under `Resources/<agent>-shim/` with its
  installer, and the provider's display strings in `Localizable.xcstrings`.
  Directory names and environment variable names come from the descriptor and
  recipe through `AgentProviderRegistry`; nothing in Swift should spell them.

---

## See also

- [`AGENTS.md`](AGENTS.md) §3 — Swift conventions a linter can't enforce
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — PR conventions, branch
  prefixes, commit message style
