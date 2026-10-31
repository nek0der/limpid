// WeirApp.swift
// Weir — app entry. Owns AppState (the dependency graph), wires the
// SwiftUI scenes, and installs global keyboard commands. The project
// windows are app-owned (`ProjectWindowPresenter`), not a scene's.

import AppKit
import OSLog
import Sparkle
import SwiftUI

private let log = Logger.weir("boot")

@MainActor
@Observable
final class AppState {
    let ghosttyApp: GhosttyApp?
    let registry = SurfaceRegistry()
    /// Polls which panes are showing tmux so the pane strip's tabs can
    /// mark them. Declared here rather than built in `init` because it needs
    /// nothing but its collaborators, which are handed to `start`.
    let tmuxPresence = TmuxPanePresence()
    /// One draft pool for the whole app: every review surface opened on
    /// the same repository root shares a `ReviewDraftWriter`, so two surfaces
    /// can never race each other writing the same on-disk draft. Owned
    /// here because the environment default only stands in for Previews
    /// and tests.
    let reviewWriters: ReviewDraftWriterPool
    /// Whether this run may write the person's files, decided once at
    /// launch: a demo run (`WEIR_DEMO=1`) writes none of them, so the
    /// build the person runs keeps its own. Every writer of those files —
    /// the stores, the session, the agent projection, the Codex config, and
    /// the record directories a pane's agent is told — is handed this value
    /// rather than reading the demo flag itself. The flag is still read
    /// directly where demo mode changes what is shown (the locale, the
    /// appearance and the font, the shell prompt), and by the approval
    /// service registrar, which would replace a system registration rather
    /// than write a file. The pull-request marks and the Git facts are
    /// chosen here (`prStatusSource`, `stagedGitFacts`).
    let writesUserFiles: Bool
    /// `writesUserFiles` as decided at launch, for the stores made as
    /// AppState's properties: whether one writes, or stands in for demo
    /// mode, is decided here and nowhere else.
    static let writesUserFilesAtLaunch = !DemoFixture.isDemoActive
    /// What demo mode shows in place of the agent projection's passes.
    static var stagedProjection: StagedProjection? {
        writesUserFilesAtLaunch ? nil : DemoFixture.stagedProjection
    }

    /// Where the pull-request marks come from: the forge CLIs, or in demo
    /// mode the fixture's requests, which ask no CLI.
    static var prStatusSource: PRStatusSource {
        writesUserFilesAtLaunch ? .live(locator: ToolLocator()) : .fixture(DemoFixture.prStatus)
    }

    /// The Git facts demo mode shows in place of reading its folders, which
    /// do not exist; `nil` in a run that reads them from Git.
    static var stagedGitFacts: [ContainerID: GitFacts]? {
        writesUserFilesAtLaunch ? nil : DemoFixture.gitFacts
    }

    /// The folder the panes' scrollback is saved in at ⌘Q and a tab's close,
    /// and replayed from at launch, handed to the session
    /// (`WorkspaceSession.scrollbackFiles`).
    static var scrollbackFiles: ScrollbackFiles {
        ScrollbackFiles(directory: WeirPaths.applicationSupportDirectory().appendingPathComponent("scrollback", isDirectory: true))
    }

    let session: WorkspaceSession
    /// The main windows' display state and the panes they report visible.
    let windowRegistry: WindowRegistry
    /// Keeps the registry told whether Weir is in front and VoiceOver runs.
    private var appVisibilityObserver: AppVisibilityObserver?
    /// Attention-ring state — the runtimes and the finished-turn viewed
    /// marks. The list and ⌘J are `attentionQueue`'s. See
    /// `AttentionState` for the responsibility split with `WorkspaceSession`.
    let attention: AttentionState
    /// Transient approval projection, intentionally excluded from persistence.
    let approvalPresentation = ApprovalPresentationStore()
    /// The attention list every window reads. Rebuilt from its sources,
    /// never saved.
    let attentionQueue = AttentionQueueStore()
    /// Set once the attention list has taken in what was already waiting at
    /// launch, which is not announced.
    @ObservationIgnored var hasMatchedRuntimes = false
    /// What the launch's readings of the restore journals found and the
    /// person has not acted on: each reading adds to it, so one toast
    /// offers Undo for all of them rather than the last reading's alone.
    @ObservationIgnored var launchRecovery = RestoreCoordinator.RecoveryReport()
    /// The panes the person could see at the last look, so a pane coming
    /// into sight is told from one that stayed.
    @ObservationIgnored var seenPanesAtLastLook: Set<UUID> = []
    /// The ended turns that were in sight while their end snapshot was
    /// still being taken, read once it settles as no change
    /// (`TurnReadRules`). For this launch only, as a turn's sight is.
    @ObservationIgnored var turnsSeenWhilePending: Set<TurnID> = []
    /// This holds the restored turns last worked out, with what they were
    /// worked out from (`restoredTurnIDs`). It is `nil` before the first ask.
    @ObservationIgnored var restoredTurnsMemo: RestoredTurnsMemo?
    /// The requests whose banners were posted and may still be up, so each
    /// is taken back once it can no longer be acted on from.
    @ObservationIgnored var announcedRequestKeys: Set<ApprovalKey> = []
    /// The wake observation `startNotificationRouting` installed. Optional
    /// because it exists only once routing has started.
    @ObservationIgnored var wakeObservation: (any NSObjectProtocol)?
    /// Keeps the bundled LaunchAgent aligned with the signed app artifact.
    let agentIntegrationServiceRegistrar = AgentIntegrationServiceRegistrar()
    /// The window the approval service's trouble is told in while it lasts
    /// (`startNoticePlacement`). `nil` while there is none.
    private(set) var serviceIssueWindowID: WindowID?
    /// The window the pending clipboard request is asked in
    /// (`startNoticePlacement`). `nil` while there is none.
    private(set) var clipboardRequestPlacement: ClipboardRequestPlacement?
    /// Why settings stopped saving as this launch began, until the alert
    /// that tells it is answered (`SavingSuspendedNotice.atLaunch`). Told
    /// at launch rather than left to Settings → General, which the person
    /// may never open: every change they make is lost when Weir quits.
    /// `nil` once answered, and while settings are saved.
    private(set) var launchSavingSuspension: SettingsSavingSuspension?
    /// The window that alert is shown in (`startNoticePlacement`). `nil`
    /// while there is none.
    private(set) var savingNoticeWindowID: WindowID?
    let store: SessionStore
    // Dependency graph — owned here so the rest of the app can read
    // these via explicit constructor injection instead of `.shared`.
    let notificationManager: WeirNotificationManager
    let historyStore: NotificationHistoryStore
    /// The agents' plan usage the rail's usage panel shows.
    let planUsageStore: PlanUsageStore
    let dragState: WeirDragState
    /// Toast bus with one slot per window: a transient banner, often with
    /// an Undo button, in place of a blocking confirmation (hiding a
    /// worktree, a restore, a discarded hunk).
    let toastCenter: ToastCenter
    /// Reduces every provider's on-disk records into what the panes show and
    /// what has to happen to the files, for every provider the Rust registry
    /// declares.
    let agentProjection: AgentProjectionAdapter
    /// What each pane's program last reported about itself over OSC 7501,
    /// which the projection reads and which leaves an agent's own titles off
    /// its tab.
    let programStatus = PaneProgramStatusStore()
    /// Restores of a worktree to the start of a turn, and their journals.
    /// Demo mode runs none: its worktrees are a fixture's, and nothing of
    /// the person's is written (`writesUserFilesAtLaunch`).
    let restores = RestoreCoordinator(
        stateDirectories: RestoreCoordinator.stateDirectories(under: WeirPaths.applicationSupportDirectory()),
        bridge: AppState.writesUserFilesAtLaunch ? .rust : .inert,
        pendingStopsURL: AppState.writesUserFilesAtLaunch
            ? WeirPaths.applicationSupportDirectory().appendingPathComponent(RestorePendingStopFile.fileName)
            : nil
    )
    /// Drives the bottom-of-window banner that asks "Move to
    /// worktree X?" whenever Claude `cd`s into a worktree the
    /// current tab doesn't own.
    let worktreeMoveSuggester: WorktreeMoveSuggester
    /// Installs our lifecycle hooks into Codex: the flags every Codex
    /// pty carries, trust included, and the removal of the trust tables
    /// earlier builds wrote into the user's own `~/.codex/config.toml`.
    let codexHookInstaller: CodexHookInstaller
    /// User preferences store. Owned by `AppState` so libghostty gets
    /// the initial values at boot and live-reload routes through here.
    let settingsStore: SettingsStore
    /// Command palette frecency scoring. Debounce-saved alongside
    /// notifications; flushed synchronously on app termination.
    let frecencyStore: FrecencyStore
    /// The turns read by having their pane in sight, kept across launches.
    let turnReads: TurnReadStore
    /// How far the person has viewed each conversation.
    let viewedLines: ViewedLineStore
    /// Each session folder's Git top level, which the changes panel and
    /// its rail count share, and how a recorded root is matched to it. The
    /// review tab asks Git for its top level as it opens, so a failure
    /// reaches the person in Git's own words, and matches through this.
    /// In demo mode each staged folder is its own top level: the fixture's
    /// folders do not exist, and Git is not asked.
    let repositoryRoots: RepositoryRoots
    /// Each worktree path's spelling with its links followed, one for the
    /// app: the repository roots, the restores, and the review's discards
    /// meet on it, and the registry lets go of a removed project's. In
    /// demo mode nothing is resolved, as the staged folders do not exist.
    let worktreePaths = AppState.writesUserFilesAtLaunch ? WorktreePathResolver() : WorktreePathResolver(resolveLinks: { $0 })
    /// This keeps what turns say after each range a review tab reads, per
    /// history revision, for every window's hunk headers (`ReviewLaterTurns`).
    let reviewLaterTurns = ReviewLaterTurns()
    /// The identity colors of each session container's active conversations.
    /// Here, one for the app, rather than on a window: the changes panel,
    /// the right rail, and the review read it through `changesPanelStores`,
    /// the pane strip and Open Tabs through the environment, and two windows
    /// on the same session must show a conversation in the same color. Made
    /// on first use, as it reads the restores through the app state.
    @ObservationIgnored lazy var conversationIdentities = ConversationIdentityStore(
        paletteCount: SupervisionTokens.conversationIdentity.count,
        sources: ConversationIdentityStore.Sources(
            session: session,
            repositoryRoots: repositoryRoots,
            turnHistory: agentProjection.turnHistory,
            viewedLines: viewedLines,
            attention: attention,
            restoredTurnIDs: { [unowned self] in restoredTurnIDs() }
        )
    )
    /// What each worktree's turns do not account for, and what they
    /// changed, which the changes panel and the review tab share. Demo
    /// mode hands it the fixture's counts, and it asks Git nothing.
    let worktreeChanges = WorktreeChanges(git: AppState.writesUserFilesAtLaunch ? .live : .inert(counts: DemoFixture.worktreeCounts))
    /// Each session folder's commits and uncommitted files, which the
    /// session header, the sidebar, and the changes panel share. Read only
    /// in the supervision window (`presentSupervisionWindows`). Demo mode
    /// hands it the fixture's facts, and it reads nothing.
    let gitFacts = GitFactsStore(staged: AppState.stagedGitFacts)
    /// The new sessions between their worktree and their agent: the setup
    /// running, or the stage that failed.
    let sessionLaunches = SessionLaunchStore()
    /// The stops kept until their conversation is back, across launches.
    /// Demo mode keeps them in memory only.
    let stopLedger = StopLedgerStore(writesFiles: AppState.writesUserFilesAtLaunch)
    /// Reads the stops' resumes again while any is kept
    /// (`refreshStopResumeOffers`).
    @ObservationIgnored var stopOfferRefresh: Task<Void, Never>?
    /// The agent each pane runs in front before its run has a record, read
    /// as its commands start and end. Made on first use, when the
    /// attention list is wired: it needs only the session.
    @ObservationIgnored lazy var paneAgentsInFront = PaneAgentInFrontFollower(session: session)
    /// Whether the decision bar's primary button still shows "⌘⏎".
    let primaryKeyHint: PrimaryKeyHint
    /// Hosts the OSC 52 / unsafe-paste confirmation sheet. The
    /// libghostty C callback reaches it via the static
    /// `ClipboardConfirmationCoordinator.shared` we set during init.
    let clipboardConfirmation: ClipboardConfirmationCoordinator
    /// Resolves the user's reduce-transparency choice (.system /
    /// .always / .never) against macOS's accessibility flag into a
    /// single Bool the window's Liquid Glass surfaces observe.
    let reduceTransparencyResolver: ReduceTransparencyResolver
    /// The hotkey-summoned panel with its own shell, outside the session.
    let quickTerminal: QuickTerminalController
    /// Keeps the quick terminal's global hotkey registered to match its
    /// setting. Observed by Settings for registration failures.
    let quickTerminalHotKeyCenter: QuickTerminalHotKeyCenter
    /// The settings document the observation hook last acted on, so a write
    /// that leaves it identical does not start the work below again. Which of
    /// those writes actually reach libghostty is decided by
    /// `lastAppliedConfigKey`.
    var lastAppliedSettings: WeirSettings
    /// The narrower turn limit last scheduled, waiting for the person to
    /// stop changing it (`applyTurnRetention`). Canceled when another
    /// change comes; `nil` until one has been scheduled.
    @ObservationIgnored var pendingRetention: Task<Void, Never>?
    /// These are the folders the projects held at the last change, resolved,
    /// so the next change tells which the person removed (`forgetRemovedWorktreeSpans`).
    @ObservationIgnored var knownSessionFolders: Set<String> = []
    /// What libghostty was last handed, plus whether the user's own config was
    /// included — the two together are what a reload has to differ from. Not
    /// the text itself: the suffix makes it a comparison key. See
    /// `scheduleSettingsReload`.
    var lastAppliedConfigKey: String?
    /// Coalesces a burst of settings mutations into one libghostty
    /// reload. A slider drag fires `value = Int($0)` on every delta —
    /// without this debounce, dragging font-size 11 → 16 triggers five
    /// full `ghostty_app_update_config` passes back-to-back. A ~250ms
    /// idle window collapses the drag to one apply.
    var settingsReloadDebounceTask: Task<Void, Never>?
    /// Watches `settings.json` for external edits (hand-edits, other
    /// tools) and pushes them into the in-memory store. Set up after
    /// `SettingsStore` exists so it can `reloadFromDisk()`.
    private var settingsWatcher: SettingsFileWatcher?
    private let notificationDelegate: WeirNotificationDelegate
    private var saveObserver: Any?
    private var themeObserver: Any?
    private var eventCoordinator: GhosttyEventCoordinator?
    private var dockBadgeSync: DockBadgeSync?
    /// Keeps the usage limit reset notifications pending, and takes the
    /// requests a stop's "Notify When It Resets" makes. Set once in
    /// `init`, after the stores it reads.
    private(set) var usageLimitResetSync: UsageLimitResetSync?
    /// Retires agent history rows whose runs were already handled. Observer-only, like `dockBadgeSync`.
    private var notificationReadSync: NotificationReadSync?
    private var gitSync: GitSyncCoordinator?
    /// Sidebar pull-request status and the scheduler that fills it. The
    /// hover card is each window's (`ProjectWindowState.prHover`). See each
    /// type for its own contract.
    let prStatusStore = PRStatusStore()
    private(set) var prStatusSyncer: PRStatusSyncer?
    private var turnEndPRRefresh: TurnEndPRRefresh?
    /// Set when the on-disk snapshot couldn't be restored at boot.
    /// A version mismatch or decode failure normally just dropped the
    /// file silently; surfacing it as an alert lets the user notice
    /// that the previous session's tabs / projects / history are
    /// gone before they assume it's their own muscle memory.
    var sessionLoadIssue: SessionLoadIssue?

    init() {
        // Weir owns its tab model, so disable AppKit's parallel window
        // tabbing and its automatically injected menus before window creation.
        NSWindow.allowsAutomaticWindowTabbing = false
        unsetenv(InitialPromptFile.environmentKey)

        let version = GhosttyFFI.version()
        let mode = GhosttyFFI.buildMode()
        log.notice("libghostty \(version, privacy: .public) (\(mode, privacy: .public))")

        // Build the user preferences store first so libghostty's
        // initial config picks up the on-disk values (font, theme,
        // scrollback, …) instead of running with the schema defaults
        // for one launch.
        let writesUserFiles = Self.writesUserFilesAtLaunch
        self.writesUserFiles = writesUserFiles
        self.reviewWriters = ReviewDraftWriterPool(shouldPersist: writesUserFiles)
        let settingsStore = SettingsStore(writesFiles: writesUserFiles)
        self.settingsStore = settingsStore
        self.lastAppliedSettings = settingsStore.settings
        // Stand up the clipboard sheet coordinator before GhosttyApp
        // boots — the `confirm_read_clipboard_cb` reaches it through
        // the static `shared` and we don't want a window of time
        // where a callback could fire with no UI to route into.
        let clipboardConfirmation = ClipboardConfirmationCoordinator()
        ClipboardConfirmationCoordinator.shared = clipboardConfirmation
        self.clipboardConfirmation = clipboardConfirmation
        let resolver = ReduceTransparencyResolver()
        resolver.apply(userEnabled: settingsStore.settings.appearance.transparency.isOn)
        self.reduceTransparencyResolver = resolver
        // Pin `NSApp.appearance` to the user's preference before the
        // first window appears so SwiftUI toolbar doesn't briefly
        // render under the OS appearance and then snap.
        Self.applyColorScheme(settingsStore.settings.appearance.colorScheme)

        do {
            let ghosttyApp = try GhosttyApp(settings: settingsStore.settings)
            self.ghosttyApp = ghosttyApp
            settingsStore.ghosttyConfigDiagnostics = ghosttyApp.userConfigDiagnostics
        } catch {
            log.fault("GhosttyApp init failed: \(String(describing: error), privacy: .private)")
            self.ghosttyApp = nil
        }
        let quickTerminal = Self.makeQuickTerminal(
            ghosttyApp: ghosttyApp,
            settingsStore: settingsStore,
            reduceTransparencyResolver: resolver,
            clipboard: clipboardConfirmation,
            secureInputManager: registry.secureInputManager
        )
        self.quickTerminal = quickTerminal
        self.quickTerminalHotKeyCenter = Self.makeQuickTerminalHotKeyCenter(
            isTerminalAvailable: ghosttyApp != nil,
            settingsStore: settingsStore,
            quickTerminal: quickTerminal
        )

        let store = SessionStore(
            directory: WeirPaths.applicationSupportDirectory(),
            writesFiles: writesUserFiles
        )
        self.store = store

        let session = WorkspaceSession()
        session.writesUserFiles = writesUserFiles
        session.scrollbackFiles = Self.scrollbackFiles
        // Let the session read the live scratch tabs' cwd defaults at
        // `openTab` time without importing `SettingsStore` into Core.
        session.quickTabDefaultsProvider = { [settingsStore] in
            let t = settingsStore.settings.terminal
            return (t.quickTabCwdMode, t.quickTabCwdPath)
        }
        // Demo mode shows `DemoFixture` instead of the person's session, so
        // the hero screenshot is the same on every run.
        switch writesUserFiles ? store.load() : .loaded(DemoFixture.snapshot) {
        case .absent:
            break
        case let .loaded(snapshot):
            sessionLoadIssue = session.restore(from: snapshot)
        case let .versionMismatch(found, expected):
            sessionLoadIssue = .versionMismatch(found: found, expected: expected)
        case let .decodeFailed(error):
            sessionLoadIssue = .decodeFailed(message: DisplayText(error: error))
        }
        // Always make sure the window has at least one tab to render.
        session.openLaunchTabIfNone()
        if writesUserFiles {
            InitialPromptFile.removeOrphans(keeping: Set(session.tabs.flatMap(\.initialPromptFiles.values)))
        }

        // Only takes out what earlier builds wrote: our hooks carry their
        // own trust in each pane's flags, so no pane waits on this.
        let codexHookInstaller = CodexHookInstaller.shared
        codexHookInstaller.removeLegacyTrust(writesUserFiles: writesUserFiles)
        self.codexHookInstaller = codexHookInstaller
        CodexHookInstaller.reportMissingHookHelper()

        let staged = Self.stagedProjection
        let agentProjection = AgentProjectionAdapter(writesFiles: writesUserFiles, staged: staged)
        self.agentProjection = agentProjection
        agentProjection.onProjectionApplied = { [weak approvalPresentation] session in
            approvalPresentation?.releaseStaleApprovals(in: session)
        }

        self.session = session
        repositoryRoots = Self.writesUserFilesAtLaunch ? RepositoryRoots(paths: worktreePaths) : .staged(paths: worktreePaths)
        windowRegistry = WindowRegistry(primary: session.primarySelection, worktreePaths: worktreePaths)
        let attention = AttentionState()
        self.attention = attention

        let historyStore = NotificationHistoryStore(writesFiles: writesUserFiles)
        self.historyStore = historyStore
        planUsageStore = Self.makePlanUsageStore(readsUsage: writesUserFiles)
        attention.onPaneFocused = { [weak historyStore] in historyStore?.markRead(forPanes: [$0]) }
        self.frecencyStore = FrecencyStore(writesFiles: writesUserFiles)
        self.turnReads = TurnReadStore(writesFiles: writesUserFiles)
        let viewedLines = ViewedLineStore(writesFiles: writesUserFiles)
        // Demo mode's lines, in memory only: the store writes no file and no
        // ref in a run that may not write the person's files.
        staged?.markViewedLines(in: viewedLines)
        self.viewedLines = viewedLines
        self.primaryKeyHint = PrimaryKeyHint(defaults: writesUserFiles ? .standard : nil)
        let notificationManager = WeirNotificationManager(historyStore: historyStore) { [settingsStore] in settingsStore.appLocale }
        self.notificationManager = notificationManager
        // Cwd-change → worktree-move suggestion pipeline. Every fresh
        // record hands off to the suggester which decides whether the
        // new path warrants a banner (case A/B in
        // `WorktreeMoveSuggester`).
        let worktreeMoveSuggester = WorktreeMoveSuggester()
        worktreeMoveSuggester.bind(session: session)
        self.worktreeMoveSuggester = worktreeMoveSuggester

        Self.bootstrapAgentTracking(
            projection: agentProjection,
            session: session, attention: attention,
            terminal: (tmuxPresence, registry),
            handlers: AgentTrackingHandlers(
                notifications: notificationManager,
                suggester: worktreeMoveSuggester,
                approvals: approvalPresentation
            )
        )

        self.dragState = WeirDragState()
        self.toastCenter = ToastCenter()
        let delegate = WeirNotificationDelegate()
        self.notificationDelegate = delegate
        // Hand the registry to the delegate so `willPresent` can
        // resolve a pane id back to its `SurfaceView` and ask which
        // window / responder actually has focus. Without this it
        // falls back to the older "is any Weir window key" check.
        WeirNotificationDelegate.registry = registry
        // The tap handler arrives with the attention list
        // (`connectAttentionNavigation`), which routes a notification to
        // its card or its agent's pane.
        delegate.install()

        let coordinator = makeGhosttyEventCoordinator()
        syncSecureInputPreference(from: ghosttyApp)
        self.eventCoordinator = coordinator
        GhosttyActionRouter.sink = { [weak coordinator] event in
            coordinator?.dispatch(event)
        }
        self.dockBadgeSync = DockBadgeSync(
            historyStore: historyStore,
            session: session,
            attentionCount: { [attentionQueue] in attentionQueue.queue.counts().total },
            setBadge: { [notificationManager] in notificationManager.setDockBadge($0) }
        )
        self.usageLimitResetSync = Self.makeUsageLimitResetSync(attentionQueue, settingsStore, notificationManager)
        self.notificationReadSync = NotificationReadSync(
            historyStore: historyStore,
            attention: attention,
            requests: approvalPresentation.ledger
        )
        self.gitSync = GitSyncCoordinator(session: session)

        (prStatusSyncer, turnEndPRRefresh) = Self.makePRStatusSync(session: session, store: prStatusStore, attention: attention)

        store.scheduleSave(session.makeSnapshot())

        saveObserver = installTerminateHandler()

        windowRegistry.occlusion = registry
        appVisibilityObserver = AppVisibilityObserver(registry: windowRegistry)
        startAutoSave()
        startActiveTabSync()
        startNoticePlacement()
        startSettingsConfigSync()

        // Arm the settings.json watcher last so the store + sync
        // hook are both ready before an external edit can fire.
        let watcher = SettingsFileWatcher(store: settingsStore)
        watcher.start()
        self.settingsWatcher = watcher

        // Register the ⌘Q + tab/pane close gates. Gate bodies live in
        // `AppState+QuitGate.swift`.
        registerConfirmGates()
        quickTerminalHotKeyCenter.start()
    }

    /// `AppState` is process-lifetime in shipping Weir, so deinit
    /// only runs in tests that instantiate it explicitly. Still pair
    /// every observer install with an explicit removal so the
    /// notification centers don't keep delivering events into a
    /// half-torn-down state object (and so adding a future
    /// multi-window AppState split doesn't accidentally leak
    /// observers per instance).
    isolated deinit {
        if let saveObserver {
            NotificationCenter.default.removeObserver(saveObserver)
        }
        if let themeObserver {
            DistributedNotificationCenter.default.removeObserver(themeObserver)
        }
    }

    /// Wire the static gate slots that AppKit / `CloseConfirmer`
    /// consult on user-initiated terminate / close. Done after init
    /// so `session` and `settingsStore` are fully wired before any
    /// close attempt can route through here. Weak self keeps the
    /// static slots from extending AppState's lifetime.
    private func registerConfirmGates() {
        WeirAppDelegate.quitGate = { [weak self] in
            self?.shouldAllowQuit() ?? true
        }
        CloseConfirmer.gate = { [weak self] request, answer in
            guard let self else {
                answer(true)
                return
            }
            confirmClose(request, answer: answer)
        }
    }

    // MARK: - Active-tab change hook

    /// Handles history acknowledgment and pane badge clearing when the visible tab changes.
    /// Driven off `activeTabID` changes so every navigation path —
    /// tab click, sidebar row click, ⌘1-9, ⌘[ / ⌘], ⌘⇧T
    /// restore — goes through the same code. Started after the snapshot
    /// is restored, so the person's first move is history like any other;
    /// a window that arrives later starts without a flash, so it doesn't
    /// open with a startled-looking bell ring.
    ///
    /// Per window: each window's selection moves on its own, and each
    /// records its own history (`ActiveTabChanges`).
    private func startActiveTabSync() {
        var changes = ActiveTabChanges(current: navTargets(), undrawn: session.undrawnWindowIDs)
        observeRepeatedly { [weak self] in
            guard let self else { return }
            for selection in self.session.selections.values {
                _ = selection.activeTabID
                _ = selection.activeContainerID
            }
            // A window that starts drawing its tab again arrives at it.
            _ = self.session.undrawnWindowIDs
        } onChange: { [weak self] in
            guard let self else { return }
            for change in changes.changes(current: self.navTargets(), undrawn: self.session.undrawnWindowIDs) {
                self.handleActiveTabChange(in: change.window, isInitial: change.isInitial, lastNavTarget: change.previous)
            }
        }
    }

    /// Places each notice waiting for an answer in one window as it
    /// arrives, and keeps it there until it is answered or its window is
    /// hidden (`WindowRegistry.placeNotice`): read in each window's body
    /// instead, it would follow the keyboard, and show in two windows when
    /// one read a stale order.
    private func startNoticePlacement() {
        // Read once, as the launch began: a file fixed by hand later takes
        // the Settings notice down, and an alert already answered stays so.
        launchSavingSuspension = settingsStore.savingSuspension
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = agentIntegrationServiceRegistrar.issue
            _ = clipboardConfirmation.pending?.id
            _ = launchSavingSuspension
            for window in windowRegistry.windows {
                _ = window.isHidden
            }
        } onChange: { [weak self] in
            self?.placeNotices()
        }
        placeNotices()
    }

    private func placeNotices() {
        let windows = windowRegistry
        let issueWindow = agentIntegrationServiceRegistrar.issue.map { _ in
            windows.placeNotice(keeping: serviceIssueWindowID) { windows.noticeWindow }
        }
        if serviceIssueWindowID != issueWindow {
            serviceIssueWindowID = issueWindow
        }
        let placement = clipboardConfirmation.pending.map { request in
            let kept = clipboardRequestPlacement.flatMap { $0.requestID == request.id ? $0.window : nil }
            let paneID = request.view.flatMap { registry.id(for: $0) }
            let window = windows.placeNotice(keeping: kept) { windows.requestWindow(forPane: paneID, in: session) }
            return ClipboardRequestPlacement(requestID: request.id, window: window)
        }
        if clipboardRequestPlacement != placement {
            clipboardRequestPlacement = placement
        }
        // A clipboard confirmation asked in the same window goes first: a
        // shell waits on it. The service's alert does too, as a window
        // presents one alert at a time.
        let savingWindow = launchSavingSuspension.map { _ in
            windows.placeNotice(keeping: savingNoticeWindowID) { windows.noticeWindow }
        }
        let savingWaits = savingWindow != nil && (placement?.window == savingWindow || issueWindow == savingWindow)
        if savingNoticeWindowID != (savingWaits ? nil : savingWindow) {
            savingNoticeWindowID = savingWaits ? nil : savingWindow
        }
    }

    /// Takes down the launch's saving alert once answered.
    func dismissSavingNotice() {
        launchSavingSuspension = nil
        placeNotices()
    }

    /// Whether `store` stopped saving the session for this launch, for the
    /// notice Settings → General shows (`SavingSuspendedNotice`) and the
    /// alert that the session was not restored. Never in demo mode, which
    /// does not load the person's file.
    var isSessionSavingSuspended: Bool {
        writesUserFiles && store.isSavingSuspended
    }

    /// `state.json` while `isSessionSavingSuspended`.
    var suspendedSessionFile: URL? {
        isSessionSavingSuspended ? store.fileURL : nil
    }

    /// Where each window is now.
    private func navTargets() -> [WindowID: WorkspaceSession.NavTarget] {
        session.selections.mapValues(WorkspaceSession.NavTarget.init(at:))
    }

    private func handleActiveTabChange(
        in window: WindowID,
        isInitial: Bool,
        lastNavTarget: WorkspaceSession.NavTarget
    ) {
        // Record back/forward history for every user-initiated jump.
        // `recordNavigation` no-ops when we're inside
        // `session.navigateBack` / `navigateForward`, so back/forward
        // clicks don't re-record themselves.
        if !isInitial {
            session.recordNavigation(from: lastNavTarget, in: window)
        }
        markShownTabRead(in: window, flashes: !isInitial)
    }

    /// Clears the unread marks of the tab `window` shows, as on arriving
    /// at it, flashing what was unread when `flashes`. Only while the
    /// window draws it: a hidden window, or a scratch tab another window
    /// draws, leaves the marks for when it draws it (it arrives at its tab
    /// then, `WorkspaceSession.undrawnWindowIDs`).
    private func markShownTabRead(in window: WindowID, flashes: Bool) {
        guard let tab = session.activeTab(in: window), session.windows(showing: tab.id).contains(window) else { return }
        let paneIDs = Set(tab.splitTree.allLeafIDs())
        // Only the focused leaf is visible; clearing a split tab would
        // silently retire history from background panes.
        if let focusedPaneID = tab.splitTree.focusedLeafID {
            historyStore.markRead(forPanes: [focusedPaneID])
        }
        for paneID in paneIDs where session.paneState(paneID).hasUnread {
            if flashes {
                flashPane(paneID, session: session)
            }
            session.clearUnread(paneID: paneID)
        }
    }

    // MARK: - Auto-save via Observation tracking

    /// IMPORTANT: ADDING A NEW PERSISTED FIELD?
    ///     1) Add the property to `WorkspaceSession`.
    ///     2) Mirror it into `SessionSnapshot` + `makeSnapshot` + `restore`.
    ///     3) **TOUCH IT IN `WorkspaceSession.readSavedState()`**, which the
    ///        observe block below calls, so a test can see the autosave
    ///        follow it. What it reads, and what it leaves out on purpose,
    ///        is documented there.
    private func startAutoSave() {
        observeRepeatedly { [weak self] in
            guard let self else { return }
            self.session.readSavedState()
        } onChange: { [weak self] in
            guard let self else { return }
            self.store.scheduleSave(self.session.makeSnapshot())
        }

        // Follow system appearance only when the user selected that mode.
        // The app and every surface receive the same resolved scheme; their
        // soft-reload callbacks re-evaluate the paired light/dark theme.
        themeObserver = DistributedNotificationCenter.default.addObserver(
            forName: SystemAppearance.themeChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this fires on the main thread, but
            // the observer signature isn't `@MainActor`, so the compiler
            // needs the explicit isolation handoff to let us touch
            // `settingsStore` and the MainActor helpers below.
            MainActor.assumeIsolated {
                guard let self else { return }
                let pref = self.settingsStore.settings.appearance.colorScheme
                guard pref == .system else { return }
                self.syncGhosttyColorScheme()
            }
        }
        startAgentIntegration()
    }

    /// Pin `NSApp.appearance` to the user's Appearance preference.
    /// `.system` clears the override so AppKit resolves it from the
    /// OS Appearance setting; `.light` / `.dark` force aqua /
    /// dark-aqua across every Weir window (including Settings).
    static func applyColorScheme(_ pref: ColorSchemePreference) {
        let appearance: NSAppearance? = switch pref {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        // Reach for `NSApplication.shared` (not `NSApp`) because this
        // can be called from `AppState.init` before SwiftUI has forced
        // the singleton, leaving `NSApp` nil.
        NSApplication.shared.appearance = appearance
    }

}

@main
struct WeirApp: App {
    @NSApplicationDelegateAdaptor(WeirAppDelegate.self) private var appDelegate
    @State private var state: AppState

    /// Sparkle auto-update controller. Eagerly started so the first
    /// launch check runs without waiting for a SwiftUI lifecycle event.
    /// Feed URL and EdDSA public key live in Info.plist.
    ///
    /// `startingUpdater` is gated on `!WeirPaths.isDevBuild` so a
    /// Debug build (`com.nekoder.Weir.dev`) never auto-checks /
    /// auto-installs. The "Check for Updates…" menu item still works
    /// — the controller exists, it just doesn't poll on its own.
    /// Without this gate a Debug session running alongside the
    /// installed dmg could replace its own DerivedData binary with
    /// the latest release mid-debug.
    /// Owns the `SPUStandardUpdaterController` plus the gentle-reminder
    /// user-driver delegate (which suppresses Sparkle's standard "found
    /// update" alert and writes the appcast item into `availability`
    /// instead, so the terminal column toolbar can surface its own shippingbox
    /// affordance). Once the user clicks the toolbar button we hand
    /// back to Sparkle's standard install / progress / restart UI by
    /// calling `updater.checkForUpdates()` — Sparkle re-uses the
    /// cached appcast item, so there's no second network round-trip.
    /// A demo run starts no updater at all (`UpdaterStack.init`).
    private let updaterStack = UpdaterStack(
        allowsAutomaticChecks: !WeirPaths.isDevBuild,
        startsUpdater: AppState.writesUserFilesAtLaunch
    )

    init() {
        // Weir restores nothing through AppKit: the presenter makes the
        // project windows from `state.json`, and Settings opens only when
        // asked. A scene's `.restorationBehavior(.disabled)` alone still
        // reads the state an earlier launch saved and brings that window
        // back, and every earlier build saved Settings, and its
        // main window, with restoration on. Ignoring the saved state
        // keeps either from coming back. Registered, not written, so it
        // lasts only for this process.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        let state = AppState()
        _state = State(initialValue: state)
        state.presentSupervisionWindows(updaterStack: updaterStack)
    }

    /// No scene hosts a project window: the presenter opens every one
    /// (`AppState.presentSupervisionWindows`), at launch and from the Dock.
    /// The menus hang off the Settings scene, as `.commands` needs a scene
    /// and they apply app-wide whichever one carries them.
    var body: some Scene {
        // Settings window. We DELIBERATELY use `Window(id:)` instead
        // of the SwiftUI `Settings { ... }` scene because the latter
        // does NOT pick up macOS 26's auto Liquid Glass for sidebar
        // NavigationSplitView (confirmed by Apple's own Notes /
        // Journal showing the same broken toolbar). Window scene lets
        // us apply `.windowStyle(.hiddenTitleBar)` and
        // our custom toolbar to match the main window's look.
        // The ⌘, shortcut + "Settings…" menu item are wired by hand
        // in the .commands block below.
        Window("Settings", id: Self.settingsWindowID) {
            SettingsScene()
                .environment(state.settingsStore)
                .environment(state.quickTerminalHotKeyCenter)
                .environment(state.reduceTransparencyResolver)
                .environment(\.sparkleUpdater, updaterStack.updater)
                .environment(updaterStack.stateModel)
                .environment(\.suspendedSessionFile, state.suspendedSessionFile)
                .environment(\.turnRecordsRemoved) { await state.turnsRemoved(by: $0) }
                .environment(\.reloadGhosttyConfig) { state.reloadGhosttyUserConfig() }
                // Settings is where the accent picker lives — inject
                // the same accent so the swatch row previews the live
                // value while the user clicks through hues.
                .weirAccentPropagated(
                    WeirColor.accent(for: state.settingsStore.settings.appearance.accentColor)
                )
        }
        // `.hiddenTitleBar` pulls the traffic-light triad down
        // inside the settings sidebar (matches Notes / Mail / the main
        // Weir window). Trade-off: there's no native title bar
        // to render pane names, so each pane prints its own inline
        // title via `SettingsForm`.
        .windowStyle(.hiddenTitleBar)
        // The content fixes the width and leaves the height free
        // (`SettingsScene.windowWidth`), and `.contentSize` makes those
        // the window's limits.
        .windowResizability(.contentSize)
        .defaultSize(width: SettingsScene.windowWidth, height: SettingsScene.windowHeight)
        // Settings opens only when asked, so a launch shows the presenter's
        // windows alone: the first scene of the body would otherwise open
        // at launch. `.disabled` alone would still bring back a window an
        // earlier launch saved, which the registration in `init` closes.
        // It never opens for a file or URL handed to Weir either:
        // the app delegate takes those (`application(_:open:)`).
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])
        .commands {
            // ── App menu ──────────────────────────────────────
            // "Check for Updates…" lives just under "About Weir".
            CommandGroup(after: .appInfo) {
                // Debug routes through the mock pipeline so design
                // tweaks reach both entry points without a real
                // Sparkle round-trip. Both branches share a single
                // busy-state disable via `UpdateStateModel.isBusy` so
                // the user can't kick off concurrent pipelines.
                CheckForUpdatesMenuItem(updaterStack: updaterStack)
            }
            // Replace the auto-generated "Settings…" item with one
            // that opens our `Window(id:)` Settings scene instead of
            // the abandoned SwiftUI `Settings { }` scene.
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
            TabCommands(state: state)
            NumberShortcutCommands(state: state)
            NavigationCommands(state: state)
            PaletteCommands(state: state)
            SettingsAwareFindCommands(state: state)
            // `CommandsBuilder` accepts at most ten children. The Xcode
            // that CI runs enforces the limit; grouping keeps the count
            // under it without changing the menus.
            Group {
                PaneCommands(state: state)
                HelpCommands(state: state)
                SupervisionCommands(state: state)
            }
        }

        // The menu bar item. Removing it from the menu bar
        // (⌘-drag) turns the setting off, as the toggle does.
        MenuBarExtra(isInserted: menuBarExtraInserted) {
            SupervisionMenuBarContent(state: state)
                .environment(\.locale, state.settingsStore.appLocale)
        } label: {
            SupervisionMenuBarLabel(state: state)
                .environment(\.locale, state.settingsStore.appLocale)
        }
        .menuBarExtraStyle(.window)
    }

    /// The setting, as a key path binding rather than a pair of closures:
    /// a `Binding(get:set:)` made afresh on every pass left the item out of
    /// the menu bar, with SwiftUI writing `true` back again and again (seen
    /// on macOS 27.0.1).
    private var menuBarExtraInserted: Binding<Bool> {
        Bindable(state.settingsStore).settings.general.showMenuBarExtra
    }

    /// Stable identifier the .commands block uses to open the
    /// Settings window via `openWindow(id:)`.
    static let settingsWindowID = "settings"
}

/// The window a clipboard request is asked in, with which request: a new
/// request is placed afresh.
struct ClipboardRequestPlacement: Equatable {
    let requestID: UUID
    let window: WindowID
}
