// LimpidApp.swift
// Limpid — app entry. Owns AppState (the dependency graph), wires the
// SwiftUI Scene, and installs global keyboard commands. The window
// layout itself lives in `ThreePaneLayout` (Notes 2026-style 3-pane).

import AppKit
import OSLog
import Sparkle
import SwiftUI

private let log = Logger.limpid("boot")

@MainActor
@Observable
final class AppState {
    let ghosttyApp: GhosttyApp?
    let registry = SurfaceRegistry()
    let session: WindowSession
    /// Attention-ring state — finished-turn viewed / dismissed
    /// bookkeeping, the container column Waiting list, and the ⌘J
    /// cursor. See `AttentionState` for the responsibility split
    /// with `WindowSession`.
    let attention: AttentionState
    let store: SessionStore
    // Dependency graph — owned here so the rest of the app can read
    // these via explicit constructor injection instead of `.shared`.
    let notificationManager: LimpidNotificationManager
    let historyStore: NotificationHistoryStore
    let historyPresentation: NotificationHistoryPresentation
    let dragState: LimpidDragState
    /// Window-scoped single-slot toast bus. Used by Hide-Worktree
    /// (and future "undoable lite" actions) to surface a transient
    /// banner with an Undo button instead of a blocking confirm.
    let toastCenter: ToastCenter
    /// Per-tab Claude Code session record. Bootstrapped after snapshot
    /// restore so `Tab.claudeSessionId` is repopulated before any pane
    /// mounts try to resume.
    let claudeSessionTracker: ClaudeSessionTracker
    /// Mirrors the on-disk agent lifecycle records into
    /// `Tab.claudeAgentBadges` so status icons reflect each running
    /// `claude` process.
    let claudeAgentStateTracker: ClaudeAgentStateTracker
    /// Owns the per-tab Codex CLI session record file. Mirror of
    /// `claudeSessionTracker` for the `codex` binary.
    let codexSessionTracker: CodexSessionTracker
    /// Mirrors the on-disk Codex agent lifecycle records into
    /// `Tab.codexAgentBadges`.
    let codexAgentStateTracker: CodexAgentStateTracker
    /// Watches the shim's `cwd-events` dir for fresh `CwdChanged`
    /// records. Each fresh event lands on `worktreeMoveSuggester`.
    let cwdEventTracker: CwdEventTracker
    /// Watches the shim's `worktree-events` dir for `WorktreeCreate`
    /// records (dropped by `limpid-pretool-worktree-hook` after it
    /// re-routes a Claude `git worktree add`). Each event fires a
    /// GitSync refetch so the new row appears without app-focus polling.
    let worktreeEventTracker: WorktreeEventTracker
    /// Codex parallel: own watcher on the Codex agent-states dir so
    /// `limpid-codex-pretool-worktree-hook` notifications flow into
    /// the same GitSync refetch pipeline.
    let codexWorktreeEventTracker: WorktreeEventTracker
    /// Drives the bottom-of-window banner that asks "Move to
    /// worktree X?" whenever Claude `cd`s into a worktree the
    /// current tab doesn't own.
    let worktreeMoveSuggester: WorktreeMoveSuggester
    /// Builds and refreshes the shadow `CODEX_HOME` Limpid hands to
    /// every Codex pty. Owns the symlink farm + the Limpid-managed
    /// `hooks.json` / `config.toml` mirror.
    let codexHomeRedirector: CodexHomeRedirector
    /// User preferences store. Owned by `AppState` so libghostty gets
    /// the initial values at boot and live-reload routes through here.
    let settingsStore: SettingsStore
    /// Command palette frecency scoring. Debounce-saved alongside
    /// notifications; flushed synchronously on app termination.
    let frecencyStore: FrecencyStore
    /// Hosts the OSC 52 / unsafe-paste confirmation sheet. The
    /// libghostty C callback reaches it via the static
    /// `ClipboardConfirmationCoordinator.shared` we set during init.
    let clipboardConfirmation: ClipboardConfirmationCoordinator
    /// Resolves the user's reduce-transparency choice (.system /
    /// .always / .never) against macOS's accessibility flag into a
    /// single Bool the Liquid Glass slab observes.
    let reduceTransparencyResolver: ReduceTransparencyResolver
    /// Tracks the last settings value pushed to libghostty so the
    /// observation hook below only fires `reloadConfig` when the
    /// terminal-affecting subset actually changes.
    var lastAppliedSettings: LimpidSettings
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
    private let notificationDelegate: LimpidNotificationDelegate
    private var saveObserver: Any?
    private var themeObserver: Any?
    private var eventCoordinator: GhosttyEventCoordinator?
    private var titleSync: WindowTitleSync?
    private var frameSync: WindowFrameSync?
    private var fullScreenSync: WindowFullScreenSync?
    private var dockBadgeSync: DockBadgeSync?
    private var gitSync: GitSyncCoordinator?
    /// Set when the on-disk snapshot couldn't be restored at boot.
    /// A version mismatch or decode failure normally just dropped the
    /// file silently; surfacing it as an alert lets the user notice
    /// that the previous session's tabs / projects / history are
    /// gone before they assume it's their own muscle memory.
    var sessionLoadIssue: SessionLoadIssue?

    /// Called once by `limpidWindowToolbar` when the underlying
    /// `NSWindow` is available.
    func bindWindow(_ window: NSWindow) {
        guard titleSync == nil else { return }
        titleSync = WindowTitleSync(session: session, window: window)
        frameSync = WindowFrameSync(session: session, window: window)
        fullScreenSync = WindowFullScreenSync(session: session, window: window)
    }

    init() {
        // AppKit auto-injects "Show Tab Bar / Show All Tabs / Move
        // Tab to New Window / Merge All Windows" into the View menu
        // for every `NSWindow` that opts into window tabbing. Limpid's
        // model owns its own tab list inside the window — the system
        // tab bar would be a parallel, confusing affordance — so we
        // disable window tabbing app-wide before any window comes up.
        NSWindow.allowsAutomaticWindowTabbing = false

        let version = GhosttyFFI.version()
        let mode = GhosttyFFI.buildMode()
        log.notice("libghostty \(version, privacy: .public) (\(mode, privacy: .public))")

        // Build the user preferences store first so libghostty's
        // initial config picks up the on-disk values (font, theme,
        // scrollback, …) instead of running with the schema defaults
        // for one launch.
        let settingsStore = SettingsStore()
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
            self.ghosttyApp = try GhosttyApp(settings: settingsStore.settings)
        } catch {
            log.fault("GhosttyApp init failed: \(String(describing: error), privacy: .public)")
            self.ghosttyApp = nil
        }

        let store = SessionStore()
        self.store = store

        let session = WindowSession()
        // Let the session read the live Quick Tabs cwd defaults at
        // `openTab` time without importing `SettingsStore` into Core.
        session.quickTabDefaultsProvider = { [settingsStore] in
            let t = settingsStore.settings.terminal
            return (t.quickTabCwdMode, t.quickTabCwdPath)
        }
        switch store.load() {
        case .absent:
            break
        case let .loaded(snapshot):
            sessionLoadIssue = session.restore(from: snapshot)
        case let .versionMismatch(found, expected):
            sessionLoadIssue = .versionMismatch(found: found, expected: expected)
        case let .decodeFailed(error):
            sessionLoadIssue = .decodeFailed(message: error.localizedDescription)
        }
        // Always make sure the window has at least one tab to render.
        if session.tabs.isEmpty {
            session.openTabInActiveScope()
        }

        // Re-attach Claude Code sessions captured by the shim's hook
        // on the previous run. Must happen before we hand `session`
        // to the rest of the graph so any pane that mounts can read
        // `Tab.claudeSessionId` immediately.
        let claudeSessionTracker = ClaudeSessionTracker()
        claudeSessionTracker.bootstrap(into: session)
        self.claudeSessionTracker = claudeSessionTracker

        let claudeAgentStateTracker = ClaudeAgentStateTracker()
        // notificationManager is constructed below; bootstrap is
        // deferred until after it's available so "Claude finished"
        // notifications can route through it.
        self.claudeAgentStateTracker = claudeAgentStateTracker

        // Codex CLI mirror trackers. The redirector also builds the
        // shadow CODEX_HOME synchronously so the first pty we spawn
        // already sees the Limpid-managed `hooks.json`.
        let codexHomeRedirector = CodexHomeRedirector.shared
        codexHomeRedirector.refresh()
        self.codexHomeRedirector = codexHomeRedirector

        // Order matters: the agent state tracker's PID liveness sweep
        // has to run *before* the session tracker reflects records into
        // `Tab.codexSessions`, otherwise a Codex that the user `/quit`
        // between Limpid sessions would auto-resume on next launch.
        // Codex has no SessionEnd-equivalent hook, so the only signal
        // for "user closed this session" is that the process is gone.
        let codexAgentStateTracker = CodexAgentStateTracker()
        codexAgentStateTracker.cleanupDeadSessionsOnLaunch()
        self.codexAgentStateTracker = codexAgentStateTracker

        let codexSessionTracker = CodexSessionTracker()
        codexSessionTracker.bootstrap(into: session)
        self.codexSessionTracker = codexSessionTracker

        self.session = session
        self.attention = AttentionState()

        let historyStore = NotificationHistoryStore()
        self.historyStore = historyStore
        self.frecencyStore = FrecencyStore()
        let notificationManager = LimpidNotificationManager(historyStore: historyStore)
        self.notificationManager = notificationManager
        // Defer the agent-state tracker bootstrap to here so it can
        // route "Claude finished" macOS notifications through the
        // freshly-constructed manager. The tracker itself was
        // initialised above with the session graph; only the bootstrap
        // call had to wait.
        claudeAgentStateTracker.bootstrap(
            into: session,
            attention: attention,
            notificationManager: notificationManager
        )
        codexAgentStateTracker.bootstrap(
            into: session,
            attention: attention,
            notificationManager: notificationManager
        )
        // Cwd-change → worktree-move suggestion pipeline. The tracker
        // watches the shim's `cwd-events` dir; every fresh record
        // hands off to the suggester which decides whether the new
        // path warrants a banner (case A/B in `WorktreeMoveSuggester`).
        let worktreeMoveSuggester = WorktreeMoveSuggester()
        worktreeMoveSuggester.bind(session: session)
        self.worktreeMoveSuggester = worktreeMoveSuggester
        let cwdEventTracker = CwdEventTracker()
        cwdEventTracker.bootstrap(into: session) { [weak worktreeMoveSuggester] record in
            worktreeMoveSuggester?.handleEvent(record)
        }
        self.cwdEventTracker = cwdEventTracker

        // Worktree-events: the PreToolUse hooks drop a JSON record
        // after they re-route an agent's `git worktree add`. One
        // tracker per agent-states dir; both share the same handler
        // (defined on `WorktreeEventTracker` so this init stays under
        // the file-length cap).
        let worktreeEventHandler = WorktreeEventTracker.gitSyncRefetchHandler(for: session)
        let worktreeEventTracker = WorktreeEventTracker(
            agentStatesDirectory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("agent-states", isDirectory: true)
        )
        worktreeEventTracker.bootstrap(handler: worktreeEventHandler)
        self.worktreeEventTracker = worktreeEventTracker

        let codexWorktreeEventTracker = WorktreeEventTracker(
            agentStatesDirectory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("codex-agent-states", isDirectory: true)
        )
        codexWorktreeEventTracker.bootstrap(handler: worktreeEventHandler)
        self.codexWorktreeEventTracker = codexWorktreeEventTracker

        self.historyPresentation = NotificationHistoryPresentation()
        self.dragState = LimpidDragState()
        self.toastCenter = ToastCenter()
        let delegate = LimpidNotificationDelegate()
        self.notificationDelegate = delegate
        // Hand the registry to the delegate so `willPresent` can
        // resolve a pane id back to its `SurfaceView` and ask which
        // window / responder actually has focus. Without this it
        // falls back to the older "is any Limpid window key" check.
        LimpidNotificationDelegate.registry = registry
        // Tap-to-jump: when the user clicks a delivered notification,
        // route through `jumpToPane` so we land on the originating
        // pane — the active-tab observer further down takes care of
        // markRead / Dock badge decrement on the resulting tab swap.
        // Closure body lives in `handleNotificationTap` so `init`'s
        // cyclomatic complexity doesn't balloon.
        LimpidNotificationDelegate.onTap = { [weak session, registry] payload in
            guard let session else { return }
            AppState.handleNotificationTap(payload, session: session, registry: registry)
        }
        delegate.install()

        let coordinator = GhosttyEventCoordinator(
            session: session, registry: registry,
            notificationManager: notificationManager, attention: attention
        )
        self.eventCoordinator = coordinator
        GhosttyActionRouter.sink = { [weak coordinator] event in
            coordinator?.dispatch(event)
        }
        self.dockBadgeSync = DockBadgeSync(
            session: session,
            notificationManager: notificationManager
        )
        self.gitSync = GitSyncCoordinator(session: session)

        store.scheduleSave(session.makeSnapshot())

        saveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak session, store, historyStore, frecencyStore, settingsStore, registry, codexAgentStateTracker] _ in
            guard let session else { return }
            MainActor.assumeIsolated {
                // Ask libghostty to dump every live surface's scrollback
                // to disk so the next launch can replay it. ⌘Q path only —
                // crashes lose anything since the last debounced auto-save
                // (which doesn't include scrollback).
                session.captureScrollbackPaths(from: registry)
                // Blank out the `pid` field on every codex state record
                // that points at a still-running codex. Limpid is about to
                // kill those processes alongside its own exit; without
                // this step the next launch's PID sweep would mistake the
                // forced kill for a `/quit` and drop the resume record.
                // Records whose codex already exited (user typed `/quit`
                // before ⌘Q) keep their dead pid → sweep deletes →
                // session correctly not restored.
                codexAgentStateTracker.preserveLiveSessionsOnTerminate()
                store.saveSynchronously(session.makeSnapshot())
                historyStore.flushSynchronously()
                frecencyStore.flushSynchronously()
                // Flush any pending settings.json write — a slider tick
                // or accent pick inside the 250 ms debounce window would
                // otherwise be cancelled as the process tears down.
                settingsStore.flushSynchronously()
            }
        }

        startAutoSave()
        startActiveTabSync()
        startSettingsConfigSync()

        // Arm the settings.json watcher last so the store + sync
        // hook are both ready before an external edit can fire.
        let watcher = SettingsFileWatcher(store: settingsStore)
        watcher.start()
        self.settingsWatcher = watcher

        // Register the ⌘Q + tab/pane close gates. Gate bodies live in
        // `AppState+QuitGate.swift`.
        registerConfirmGates()
    }

    /// `AppState` is process-lifetime in shipping Limpid, so deinit
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
        LimpidAppDelegate.quitGate = { [weak self] in
            self?.shouldAllowQuit() ?? true
        }
        CloseConfirmer.gate = { [weak self] request in
            self?.shouldAllowClose(request) ?? true
        }
    }

    // MARK: - Active-tab change hook

    /// Single hook point for "the user is now looking at this tab":
    ///   1. Mark every history entry for the tab's panes as read.
    ///   2. Flash each pane that was carrying an unread badge, then
    ///      clear the badge.
    /// Driven off `activeTabID` changes so every navigation path —
    /// TabRow click, container-header click, ⌘1-9, ⌘[ / ⌘], ⌘⇧T
    /// restore — goes through the same code. Initial fire (snapshot
    /// restore at launch) suppresses the flash so a fresh window
    /// doesn't start with a startled-looking bell ring.
    private func startActiveTabSync() {
        var isInitialFire = true
        var lastNavTarget = session.currentNavTarget
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = self.session.activeTabID
            _ = self.session.activeContainerID
        } onChange: { [weak self] in
            guard let self else { return }
            self.handleActiveTabChange(isInitial: isInitialFire, lastNavTarget: lastNavTarget)
            lastNavTarget = self.session.currentNavTarget
            isInitialFire = false
        }
    }

    private func handleActiveTabChange(
        isInitial: Bool,
        lastNavTarget: WindowSession.NavTarget
    ) {
        // Record back/forward history for every user-initiated jump.
        // `recordNavigation` no-ops when we're inside
        // `session.navigateBack` / `navigateForward`, so back/forward
        // clicks don't re-record themselves.
        if !isInitial {
            session.recordNavigation(from: lastNavTarget)
        }

        guard let tab = session.activeTab else { return }
        let paneIDs = Set(tab.splitTree.allLeafIDs())
        historyStore.markRead(forPanes: paneIDs)
        for paneID in paneIDs where session.paneState(paneID).hasUnread {
            if !isInitial {
                flashPane(paneID, session: session)
            }
            session.clearUnread(paneID: paneID)
        }
    }

    // MARK: - Auto-save via Observation tracking

    /// IMPORTANT: ADDING A NEW PERSISTED FIELD?
    ///     1) Add the property to `WindowSession`.
    ///     2) Mirror it into `SessionSnapshot` + `makeSnapshot` + `restore`.
    ///     3) **TOUCH IT IN THE OBSERVE BLOCK BELOW.**
    ///
    /// The pre-F4 hook also looped `for tab in tabs { _ = tab.paneStates }`
    /// which was both redundant (`_ = tabs` already tracks every
    /// mutation to `tabs[idx]`) and a performance trap: bell-ring and
    /// child-exit toggles reassigned `tabs[idx]`, so every BEL caused
    /// a debounced encode of the full snapshot. The transient bits
    /// moved to `WindowSession.paneTransients`, which is intentionally
    /// NOT observed here — autosave should not see them. The
    /// remaining `_ = tabs` covers every persistable tab mutation
    /// (title, splitTree, container, scrollbackPaths, unreadCount on
    /// `Tab.paneStates`).
    private func startAutoSave() {
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = self.session.tabs
            _ = self.session.projects
            _ = self.session.groups
            _ = self.session.activeTabID
            _ = self.session.activeContainerID
            _ = self.session.sidebarWidth
            _ = self.session.tabColumnWidth
            _ = self.session.sidebarHidden
            _ = self.session.windowFrame
            // `SessionSnapshot` also persists these three fields; if
            // the user toggles tab layout, drags the Waiting region
            // divider, or recents-bumps a project without any other
            // tracked field changing in the same tick, autosave would
            // miss the mutation and a crash before the next tracked
            // change would lose it. Keep the observation block aligned
            // with `makeSnapshot()`.
            _ = self.session.tabColumnHorizontal
            _ = self.session.attentionHeightFraction
            _ = self.session.recentProjectPaths
        } onChange: { [weak self] in
            guard let self else { return }
            self.store.scheduleSave(self.session.makeSnapshot())
        }

        // Live light/dark switching. libghostty can't follow macOS
        // appearance on its own when embedded (ghostty#11017), so we
        // listen for the distributed
        // `AppleInterfaceThemeChangedNotification` and rebuild the
        // config so every surface re-picks its theme. Surfaces
        // refresh through the existing `ghostty_app_update_config`
        // path that Settings → Appearance already uses.
        themeObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this fires on the main thread, but
            // the observer signature isn't `@MainActor`, so the compiler
            // needs the explicit isolation handoff to let us touch
            // `settingsStore` and the MainActor helpers below.
            MainActor.assumeIsolated {
                guard let self, let app = self.ghosttyApp else { return }
                // OS-side change matters only when the user is set to
                // `.system`; `.light` / `.dark` overrides ignore the OS
                // signal (libghostty stays on the pinned theme, NSApp
                // appearance was already applied in init / settings sync).
                let pref = self.settingsStore.settings.appearance.colorScheme
                guard pref == .system else { return }
                GhosttyConfigBridge.reloadConfig(
                    app: app,
                    settings: self.settingsStore.settings,
                    resourcesDir: GhosttyApp.resolveResourcesDir(),
                    includeUserConfig: self.settingsStore.settings.advanced.ghosttyConfig.isOn,
                    appearance: GhosttyApp.currentAppearance(preference: pref),
                    surfaces: self.registry.allViews
                )
            }
        }
    }

    /// Pin `NSApp.appearance` to the user's Appearance preference.
    /// `.system` clears the override so AppKit resolves it from the
    /// OS Appearance setting; `.light` / `.dark` force aqua /
    /// dark-aqua across every Limpid window (including Settings).
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

    /// Resolve a notification tap to the most-specific surviving
    /// target. `NSApp.activate` already ran in the delegate, so when
    /// every level has been deleted between fire and tap we leave
    /// the user on whatever they had open instead of navigating to
    /// a phantom container.
    static func handleNotificationTap(
        _ payload: NotificationTapPayload,
        session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        if let paneID = payload.paneID,
           session.tab(containing: paneID) != nil
        {
            jumpToPane(paneID, session: session, registry: registry)
            return
        }
        if let tabID = payload.tabID, session.tab(tabID) != nil {
            session.setActiveTab(tabID)
            return
        }
        if let containerID = payload.containerID,
           session.containerExists(containerID)
        {
            session.setActiveContainer(containerID)
        }
    }
}

@main
struct LimpidApp: App {
    @NSApplicationDelegateAdaptor(LimpidAppDelegate.self) private var appDelegate
    @State private var state = AppState()

    /// Sparkle auto-update controller. Eagerly started so the first
    /// launch check runs without waiting for a SwiftUI lifecycle event.
    /// Feed URL and EdDSA public key live in Info.plist.
    ///
    /// `startingUpdater` is gated on `!LimpidPaths.isDevBuild` so a
    /// Debug build (`dev.limpid.Limpid.dev`) never auto-checks /
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
    private let updaterStack = UpdaterStack(
        allowsAutomaticChecks: !LimpidPaths.isDevBuild
    )

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 640, minHeight: 400)
                .containerBackground(.regularMaterial, for: .window)
                // Tag this window's underlying NSWindow as a Limpid
                // main window so `LimpidUpdateDriver.hasInlineTarget`
                // can distinguish it from the Settings window when
                // deciding whether to surface the inline updater UI
                // vs. fall back to Sparkle's standard alert.
                .background(LimpidMainWindowMarker())
                .environment(state.session)
                .environment(state.attention)
                .environment(state.historyStore)
                .environment(state.historyPresentation)
                .environment(state.dragState)
                .environment(state.toastCenter)
                .environment(state.worktreeMoveSuggester)
                .environment(state.settingsStore)
                .environment(state.reduceTransparencyResolver)
                .environment(\.surfaceRegistry, state.registry)
                .environment(\.claudeSessionTracker, state.claudeSessionTracker)
                .environment(\.codexSessionTracker, state.codexSessionTracker)
                .environment(\.cwdEventTracker, state.cwdEventTracker)
                .environment(\.frecencyStore, state.frecencyStore)
                .environment(\.notificationManager, state.notificationManager)
                .environment(\.sparkleUpdater, updaterStack.updater)
                .environment(updaterStack.stateModel)
                .environment(\.locale, state.settingsStore.appLanguage.locale ?? .current)
                // Inject the user's accent as both `\.limpidAccent`
                // (Limpid toolbar) and SwiftUI's `\.tint` (its own
                // Toggle / Slider / etc.). Sheets and popovers re-apply
                // via `View.limpidAccentPropagated(_:)` at their
                // callsite — macOS detaches their presentation, so
                // these don't reach inside.
                .limpidAccentPropagated(
                    LimpidColor.accent(for: state.settingsStore.settings.appearance.accentColor)
                )
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // ── App menu ──────────────────────────────────────
            // "Check for Updates…" lives just under "About Limpid".
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
            // ── File menu ──────────────────────────────────────
            CommandGroup(replacing: .newItem) {
                Button {
                    TabActions.newTab(state.session)
                } label: {
                    Label("New Tab", systemImage: "plus.rectangle")
                }
                .limpidShortcut(.newTab, in: state.settingsStore)
                // ⌘⌥N raises the Create Worktree sheet for the active
                // project. Routed through a Notification so the
                // sidebar (which owns the sheet state) can present it
                // without us reaching across the view tree. Disabled
                // when the active container isn't a project — the
                // worktree concept doesn't apply to Quick Tabs or
                // Groups.
                Button {
                    NotificationCenter.default.post(
                        name: .limpidCreateWorktreeRequested,
                        object: nil
                    )
                } label: {
                    Label("New Worktree…", systemImage: "arrow.triangle.branch")
                }
                .limpidShortcut(.newWorktree, in: state.settingsStore)
                .disabled(state.session.activeContainerID.projectID == nil)
                Button {
                    TabActions.renameActiveTab(state.session)
                } label: {
                    Label("Rename Tab", systemImage: "pencil")
                }
                .limpidShortcut(.renameTab, in: state.settingsStore)
                .disabled(state.session.activeTab == nil)
                Button {
                    TabActions.reopenClosedTab(state.session)
                } label: {
                    Label("Reopen Closed Tab", systemImage: "arrow.uturn.backward.square")
                }
                .limpidShortcut(.reopenClosedTab, in: state.settingsStore)
                .disabled(state.session.closedTabStack.isEmpty)
            }
            CommandGroup(after: .newItem) {
                // ⌘W — closes the focused pane, cascades
                // to the tab when only one pane is left. Single-icon
                // family across the whole app (plain `xmark`) so
                // every "close X" affordance reads as the same verb.
                Button {
                    PaneActions.closeActivePaneOrTab(
                        state.session,
                        registry: state.registry,
                        claudeSessionTracker: state.claudeSessionTracker,
                        codexSessionTracker: state.codexSessionTracker,
                        cwdEventTracker: state.cwdEventTracker
                    )
                } label: {
                    Label("Close Pane", systemImage: "xmark")
                }
                .limpidShortcut(.closeSurface, in: state.settingsStore)
                .disabled(state.session.activeTab == nil)
                // ⌘⌥W → close the entire tab regardless of how many
                // panes it contains (no per-pane cascade).
                Button {
                    TabActions.closeActiveTab(
                        state.session,
                        registry: state.registry,
                        claudeSessionTracker: state.claudeSessionTracker,
                        codexSessionTracker: state.codexSessionTracker,
                        cwdEventTracker: state.cwdEventTracker
                    )
                } label: {
                    Label("Close Tab", systemImage: "xmark.rectangle")
                }
                .limpidShortcut(.closeTab, in: state.settingsStore)
                .disabled(state.session.activeTab == nil)
            }
            // ── View menu ─────────────────────────────────────
            CommandGroup(after: .sidebar) {
                Button {
                    withAnimation(LimpidMotion.sidebarToggle) {
                        state.session.sidebarHidden.toggle()
                    }
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .limpidShortcut(.toggleSidebar, in: state.settingsStore)
                Button {
                    state.session.tabColumnHorizontal.toggle()
                } label: {
                    Label("Toggle Tab Layout", systemImage: "rectangle.topthird.inset.filled")
                }
                .limpidShortcut(.toggleTabLayout, in: state.settingsStore)
            }
            NumberShortcutCommands(state: state)
            NavigationCommands(state: state)
            CommandGroup(after: .toolbar) {
                Button {
                    CommandPaletteActions.openCommandPalette(
                        state.session,
                        settings: state.settingsStore,
                        frecencyStore: state.frecencyStore,
                        attention: state.attention
                    )
                } label: {
                    Label("Command Palette", systemImage: "text.magnifyingglass")
                }
                .limpidShortcut(.commandPalette, in: state.settingsStore)

                Button {
                    CommandPaletteActions.openCommandPalette(
                        state.session,
                        settings: state.settingsStore,
                        frecencyStore: state.frecencyStore,
                        attention: state.attention,
                        initialQuery: ""
                    )
                } label: {
                    Label("Quick Open", systemImage: "magnifyingglass")
                }
                .limpidShortcut(.quickOpen, in: state.settingsStore)

                Button {
                    state.historyPresentation.isPresented.toggle()
                } label: {
                    Label("Notification History", systemImage: "bell")
                }
                .limpidShortcut(.notificationHistory, in: state.settingsStore)
            }
            CommandGroup(after: .textEditing) {
                // Find affordances are pane-scoped — the in-pane
                // overlay lives on the active surface, so without
                // one there's nothing to search. The Section
                // disables on `activeTab`; the per-button gates on
                // findNext/findPrevious tighten further so they only
                // light up once a search overlay actually exists.
                let focusedPaneID = state.session.activeTab?.splitTree.effectiveFocusedLeafID
                let hasActiveSearch = focusedPaneID.map {
                    state.session.paneSearchStates[$0] != nil
                } ?? false
                Section {
                    Button {
                        SearchActions.beginSearch(state.session)
                    } label: {
                        Label("Find…", systemImage: "magnifyingglass")
                    }
                    .limpidShortcut(.find, in: state.settingsStore)
                    Button {
                        SearchActions.searchNext(state.session, registry: state.registry)
                    } label: {
                        Label("Find Next", systemImage: "chevron.down")
                    }
                    .limpidShortcut(.findNext, in: state.settingsStore)
                    .disabled(!hasActiveSearch)
                    Button {
                        SearchActions.searchPrevious(state.session, registry: state.registry)
                    } label: {
                        Label("Find Previous", systemImage: "chevron.up")
                    }
                    .limpidShortcut(.findPrevious, in: state.settingsStore)
                    .disabled(!hasActiveSearch)
                }
                .disabled(state.session.activeTab == nil)
            }
            PaneCommands(state: state)
        }

        // Settings window. We DELIBERATELY use `Window(id:)` instead
        // of the SwiftUI `Settings { ... }` scene because the latter
        // does NOT pick up macOS 26's auto Liquid Glass for sidebar
        // NavigationSplitView (confirmed by Apple's own Notes /
        // Journal showing the same broken toolbar). Window scene lets
        // us apply `.windowStyle(.hiddenTitleBar)` and
        // our custom toolbar to match the main window's look.
        // The ⌘, shortcut + "Settings…" menu item are wired by hand
        // in the .commands block above.
        Window("Settings", id: Self.settingsWindowID) {
            SettingsScene()
                .environment(state.settingsStore)
                .environment(state.reduceTransparencyResolver)
                .environment(\.sparkleUpdater, updaterStack.updater)
                .environment(updaterStack.stateModel)
                // Settings is where the accent picker lives — inject
                // the same accent so the swatch row previews the live
                // value while the user clicks through hues.
                .limpidAccentPropagated(
                    LimpidColor.accent(for: state.settingsStore.settings.appearance.accentColor)
                )
        }
        // `.hiddenTitleBar` pulls the traffic-light triad down
        // inside the sidebar slab (matches Notes / Mail / the main
        // Limpid window). Trade-off: there's no native title bar
        // to render pane names, so each pane prints its own inline
        // title via `SettingsForm`.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 540)
    }

    /// Stable identifier the .commands block uses to open the
    /// Settings window via `openWindow(id:)`.
    static let settingsWindowID = "settings"
}

struct ContentView: View {
    let state: AppState
    @State private var loadIssue: SessionLoadIssue?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let app = state.ghosttyApp {
                ThreePaneLayout(state: state, app: app)
                    .animation(LimpidMotion.sidebarToggle, value: state.session.sidebarHidden)
            } else {
                LibghosttyInitFailureView()
                    .environment(state)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            ToastHost()
        }
        .overlay(alignment: .bottom) {
            WorktreeMoveSuggestionHost()
        }
        .overlay {
            if let paletteState = state.session.commandPaletteState,
               state.session.paletteFieldFrame.width > 0
            {
                GeometryReader { overlayGeo in
                    let overlayOrigin = overlayGeo.frame(in: .global).origin
                    let fieldFrame = state.session.paletteFieldFrame
                    let dropX = fieldFrame.midX - overlayOrigin.x - 200
                    let dropY = fieldFrame.maxY - overlayOrigin.y + 6

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            CommandPaletteActions.closeCommandPalette(state.session)
                        }
                    CommandPaletteDropdown(
                        state: paletteState,
                        onDismiss: {
                            CommandPaletteActions.closeCommandPalette(state.session)
                        }
                    )
                    .frame(width: 400)
                    .frame(maxHeight: 360)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: dropX, y: dropY)
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(LimpidMotion.paletteToggle, value: state.session.commandPaletteState != nil)
        .onReceive(NotificationCenter.default.publisher(for: .limpidCommandPaletteExecute)) { note in
            guard let action = note.object as? CommandPaletteAction else { return }
            CommandPaletteActions.executeCommandPaletteAction(
                action,
                session: state.session,
                attention: state.attention,
                registry: state.registry,
                frecencyStore: state.frecencyStore,
                toastCenter: state.toastCenter,
                minPaneSize: state.settingsStore.settings.terminal.minPaneSize,
                claudeSessionTracker: state.claudeSessionTracker,
                codexSessionTracker: state.codexSessionTracker,
                cwdEventTracker: state.cwdEventTracker
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .limpidToggleNotificationHistory)) { _ in
            state.historyPresentation.isPresented.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .limpidOpenSettings)) { _ in
            openWindow(id: LimpidApp.settingsWindowID)
        }
        .sheet(item: Binding(
            get: { state.clipboardConfirmation.pending },
            set: { newValue in
                // The system also drives this binding to nil when the
                // sheet is dismissed via Esc / clicking outside; treat
                // that as a Deny so libghostty always receives a
                // completion (otherwise the surface request stays open
                // forever and the embedded shell can't proceed).
                if newValue == nil, state.clipboardConfirmation.pending != nil {
                    state.clipboardConfirmation.deny()
                }
            }
        )) { request in
            ClipboardConfirmationSheet(
                request: request,
                onAllow: { state.clipboardConfirmation.allow() },
                onDeny: { state.clipboardConfirmation.deny() }
            )
            .limpidAccentPropagated(
                LimpidColor.accent(for: state.settingsStore.settings.appearance.accentColor)
            )
        }
        .limpidWindowToolbar { [state] window in
            state.bindWindow(window)
        }
        // Surface session-restore failures the first time the window
        // comes up. Pulling the issue off AppState clears it so a
        // dismiss closes the alert for the rest of the session.
        .task {
            if let issue = state.sessionLoadIssue {
                state.sessionLoadIssue = nil
                loadIssue = issue
            }
        }
        .alert(
            loadIssue?.title ?? "",
            isPresented: Binding(
                get: { loadIssue != nil },
                set: { if !$0 { loadIssue = nil } }
            ),
            presenting: loadIssue
        ) { _ in
            Button("OK", role: .cancel) { loadIssue = nil }
        } message: { issue in
            Text(issue.detail)
        }
    }
}
