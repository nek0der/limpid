// CommandPaletteActions.swift
// Limpid — command-palette verbs (open / close / execute). The
// `.shortcutAction` case reaches into `TabActions.dispatchShortcutAction`
// so the palette re-uses the same dispatch chain the menu bar runs.

import Foundation

extension Notification.Name {
    static let limpidReviewChanges = Notification.Name("dev.limpid.reviewChanges")
    static let limpidReviewTurn = Notification.Name("dev.limpid.reviewTurn")
    static let limpidReviewFind = Notification.Name("dev.limpid.reviewFind")
    /// Posted when a review paste is refused at the confirmation sheet. The
    /// comments were already recorded as sent by then — the paste action
    /// answers long before the sheet does — so this is what takes the mark
    /// back off them.
    static let limpidReviewPasteDenied = Notification.Name("dev.limpid.reviewPasteDenied")

    /// Posted by a surface when the user pastes into a pane that mirrors a
    /// tmux pane. `object` is the `SurfaceView`, so the window whose registry
    /// owns it is the one that pastes: it holds the tmux store and the toast
    /// center the view cannot reach. Declared here with the other names a
    /// view posts and a window answers, since the two sit in different
    /// layers.
    static let limpidMirrorPasteRequested = Notification.Name("dev.limpid.mirrorPasteRequested")

    /// Posted when files are dropped on a pane whose tab sends its input
    /// through tmux. `object` is the `SurfaceView`; the dropped file URLs
    /// are under `SurfaceView.droppedFileURLsKey`. Answered by the window
    /// for the same reason as `limpidMirrorPasteRequested`.
    static let limpidMirrorFileDropRequested = Notification.Name("dev.limpid.mirrorFileDropRequested")

    /// Posted when review hands its text to a pane whose tab sends its input
    /// through tmux. `object` is the `SurfaceView`; the text is under
    /// `SurfaceView.reviewPromptTextKey` and the receipt that answers for it
    /// under `SurfaceView.reviewPasteReceiptKey`. Answered by the window for
    /// the same reason as `limpidMirrorPasteRequested`.
    static let limpidMirrorReviewPasteRequested = Notification.Name("dev.limpid.mirrorReviewPasteRequested")

    /// Posted when the command palette opens so the overlay grabs focus.
    static let limpidCommandPaletteFocus = Notification.Name("dev.limpid.commandPaletteFocus")

    /// Posted by the toolbar palette field when the user presses Enter.
    /// The `object` carries the `CommandPaletteAction` to execute.
    static let limpidCommandPaletteExecute = Notification.Name("dev.limpid.commandPaletteExecute")

    /// Open the Settings window from the palette.
    static let limpidOpenSettings = Notification.Name("dev.limpid.openSettings")
}

@MainActor
enum CommandPaletteActions {
    // swiftlint:disable function_parameter_count
    /// ⌘P / ⌘⇧P — surface the palette. Idempotent: if a state
    /// already exists, focus the existing one (the overlay observes
    /// `session.commandPaletteState` and grabs focus on the next
    /// render).
    static func openCommandPalette(
        _ session: WindowSession,
        settings: SettingsStore,
        frecencyStore: FrecencyStore,
        attention: AttentionState,
        registry: (any SurfaceViewProviding)? = nil,
        // Review can be up over a container with nothing to review, and the
        // palette is one of the ways to close it.
        reviewPresentation: ReviewPresentation?,
        tmuxStore: TmuxConnectionStore?,
        // What the tmux rows read. Resolved here rather than in the catalog
        // so the catalog stays a pure function of what it is handed.
        tmuxPresence: TmuxPanePresence? = nil,
        initialQuery: String = ">"
    ) {
        if session.commandPaletteState != nil {
            NotificationCenter.default.post(name: .limpidCommandPaletteFocus, object: nil)
            return
        }
        let state = CommandPaletteState()
        state.isTmuxAvailable = tmuxStore?.tmuxExecutable != nil
        state.allItems = CommandPaletteCatalog.buildItems(
            session: session,
            settings: settings,
            attention: attention,
            registry: registry,
            reviewPresentation: reviewPresentation,
            isTmuxAvailable: state.isTmuxAvailable,
            tmux: TmuxPaletteContext.make(
                session: session,
                store: tmuxStore,
                presence: tmuxPresence,
                support: settings.agentTmuxSupport
            )
        )
        state.initialQuery = initialQuery.isEmpty ? nil : initialQuery
        state.applyFilter(query: "", frecencyStore: frecencyStore)
        session.commandPaletteState = state
        if let tmuxStore {
            loadTmuxWindows(into: state, session: session, store: tmuxStore, frecencyStore: frecencyStore)
        }
    }

    // swiftlint:enable function_parameter_count

    /// List the tmux windows after the palette is already up and merge
    /// them into it. Listing runs one client per server socket, and a
    /// socket whose server hangs costs a full timeout, so the palette never
    /// waits for it. Rows that arrive after the palette closed, or after it
    /// was reopened, are dropped.
    ///
    /// Returns the loading task so a caller can wait for the merge.
    @discardableResult
    static func loadTmuxWindows(
        into state: CommandPaletteState,
        session: WindowSession,
        store: TmuxConnectionStore,
        frecencyStore: FrecencyStore?,
        listWindows: @escaping @Sendable (String) async -> [TmuxMirrorTarget] = listTmuxWindows(tmuxPath:)
    ) -> Task<Void, Never>? {
        guard let tmuxPath = store.tmuxExecutable else { return nil }
        state.isListingTmuxWindows = true
        return Task {
            let targets = await listWindows(tmuxPath)
            guard session.commandPaletteState === state else { return }
            let items = CommandPaletteCatalog.tmuxWindowItems(targets: targets) {
                store.liveMirror(showing: $0.windowID, of: $0.binding) != nil
            }
            state.mergeItems(items, frecencyStore: frecencyStore)
        }
    }

    /// A dispatch queue rather than `Task.detached`: listing blocks on
    /// child processes, and blocking a cooperative-pool thread for a slow
    /// socket starves the concurrency runtime. The closure is formed in
    /// this nonisolated function so Dispatch never runs a closure that
    /// carries main-actor isolation.
    nonisolated static func listTmuxWindows(tmuxPath: String) async -> [TmuxMirrorTarget] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: TmuxMirrorTargetLister.targets(tmuxPath: tmuxPath))
            }
        }
    }

    /// Dismiss the palette overlay. Routine — used by Esc, the
    /// outside-tap dismissal in `ToolbarPaletteField`, and the
    /// `executeCommandPaletteAction` finaliser below.
    static func closeCommandPalette(_ session: WindowSession) {
        session.commandPaletteState = nil
    }

    // swiftlint:disable function_parameter_count
    /// Run the palette row the user committed. Records the frecency
    /// hit so the next session sorts smarter, then routes to the
    /// matching domain action and pulls focus back to the terminal
    /// surface.
    static func executeCommandPaletteAction(
        _ action: CommandPaletteAction,
        session: WindowSession,
        attention: AttentionState,
        registry: any SurfaceViewProviding,
        frecencyStore: FrecencyStore,
        toastCenter: ToastCenter,
        minPaneSize: Double,
        agentProjection: AgentProjectionAdapter? = nil,
        tmuxStore: TmuxConnectionStore?,
        // The pane poll, for the row that shows the session a pane is
        // attached to by hand. Absent in a preview, where that row is
        // never listed.
        tmuxPresence: TmuxPanePresence? = nil
    ) {
        closeCommandPalette(session)
        frecencyStore.record(action.frecencyKey)

        switch action {
        case let .shortcutAction(shortcut):
            TabActions.dispatchShortcutAction(
                shortcut,
                session: session,
                attention: attention,
                registry: registry,
                trackers: TabActions.SessionTrackers(
                    projection: agentProjection
                ),
                toastCenter: toastCenter,
                minPaneSize: minPaneSize,
                tmuxStore: tmuxStore
            )
        case let .jumpToTab(tabID):
            if let tab = session.tab(tabID) {
                session.setActiveContainer(tab.container)
                session.setActiveTab(tabID)
            }
        case let .activateGroup(groupID):
            session.setActiveContainer(.group(groupID))
        case let .activateProject(projectID):
            session.setActiveContainer(.project(projectID))
        case let .activateWorktree(pid, wid):
            session.setActiveContainer(.worktree(projectID: pid, worktreeID: wid))
        case let .reopenClosedTab(tabID):
            TmuxMirrorActions.reopenClosedTab(
                session,
                specificID: tabID,
                store: tmuxStore
            )
        case let .openRecentProject(url):
            session.addOrActivateProject(rootURL: url)
        case .openSettings:
            NotificationCenter.default.post(name: .limpidOpenSettings, object: nil)
        case .insertPrefix:
            break // Handled in ToolbarPaletteField, never reaches here.
        case .newTmuxSession, .showPaneTmuxSession, .mirrorTmuxWindow:
            executeTmuxAction(action, session: session, store: tmuxStore, presence: tmuxPresence)
        }

        // Restore focus to the terminal surface so the next keystroke
        // lands on the pane the user was working in before the palette
        // intercepted them.
        if let tab = session.activeTab,
           let leafID = tab.splitTree.effectiveFocusedLeafID,
           let view = registry.view(for: leafID)
        {
            view.window?.makeFirstResponder(view)
        }
    }

    // swiftlint:enable function_parameter_count

    /// The rows that ask something of tmux. Apart from the dispatch above
    /// because each one needs the store, and three more guards there would
    /// say the same thing three times: a row is only listed when a store
    /// exists, so a missing one is a wiring error rather than a state the
    /// user can reach.
    private static func executeTmuxAction(
        _ action: CommandPaletteAction,
        session: WindowSession,
        store: TmuxConnectionStore?,
        presence: TmuxPanePresence?
    ) {
        guard let store else { return }
        switch action {
        case .newTmuxSession:
            TmuxSessionActions.newSession(session: session, store: store)
        case let .showPaneTmuxSession(paneID):
            guard let presence else { return }
            TmuxSessionActions.showSessionInTab(
                paneID: paneID,
                session: session,
                store: store,
                presence: presence
            )
        case let .mirrorTmuxWindow(target):
            TmuxMirrorActions.openFromPalette(target, session: session, store: store)
        default:
            break
        }
    }
}
