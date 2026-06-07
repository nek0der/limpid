// CommandPaletteActions.swift
// Limpid — command-palette verbs (open / close / execute). The
// `.shortcutAction` case reaches into `TabActions.dispatchShortcutAction`
// so the palette re-uses the same dispatch chain the menu bar runs.

import Foundation

extension Notification.Name {
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
    /// ⌘P / ⌘⇧P — surface the palette. Idempotent: if a state
    /// already exists, focus the existing one (the overlay observes
    /// `session.commandPaletteState` and grabs focus on the next
    /// render).
    static func openCommandPalette(
        _ session: WindowSession,
        settings: SettingsStore,
        frecencyStore: FrecencyStore,
        attention: AttentionState,
        initialQuery: String = ">"
    ) {
        if session.commandPaletteState != nil {
            NotificationCenter.default.post(name: .limpidCommandPaletteFocus, object: nil)
            return
        }
        let state = CommandPaletteState()
        state.allItems = CommandPaletteCatalog.buildItems(
            session: session, settings: settings, attention: attention
        )
        state.initialQuery = initialQuery.isEmpty ? nil : initialQuery
        state.applyFilter(query: "", frecencyStore: frecencyStore)
        session.commandPaletteState = state
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
        claudeSessionTracker: ClaudeSessionTracker? = nil,
        codexSessionTracker: CodexSessionTracker? = nil,
        cwdEventTracker: CwdEventTracker? = nil
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
                    claude: claudeSessionTracker,
                    codex: codexSessionTracker,
                    cwdEvent: cwdEventTracker
                ),
                toastCenter: toastCenter,
                minPaneSize: minPaneSize
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
            TabActions.reopenClosedTab(session, specificID: tabID)
        case let .openRecentProject(url):
            session.addOrActivateProject(rootURL: url)
        case .openSettings:
            NotificationCenter.default.post(name: .limpidOpenSettings, object: nil)
        case .insertPrefix:
            break // Handled in ToolbarPaletteField, never reaches here.
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
}
