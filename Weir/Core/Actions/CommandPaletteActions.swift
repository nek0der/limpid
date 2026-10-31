// CommandPaletteActions.swift
// Weir — command-palette verbs (open / close / execute). The
// `.shortcutAction` case reaches into `TabActions.dispatchShortcutAction`
// so the palette re-uses the same dispatch chain the menu bar runs.

import Foundation

extension Notification.Name {
    /// Posted when the command palette opens so the overlay grabs focus. A
    /// broadcast: one palette is open at a time, in one window.
    static let weirCommandPaletteFocus = Notification.Name("com.nekoder.weir.commandPaletteFocus")

    /// Open the Settings window from the palette. A broadcast: Settings is
    /// the app's one scene, and whichever window's chrome hears it opens it.
    static let weirOpenSettings = Notification.Name("com.nekoder.weir.openSettings")
}

/// What the window did with a palette row before the shared dispatch.
enum PaletteRowHandling: Equatable {
    /// Not the window's: the shared dispatch runs it.
    case notHandled
    /// Run, and the window placed the keyboard itself.
    case handled
    /// Run, or nothing to do, and the keyboard goes back to the terminal
    /// as after any row.
    case handledReturningKeyboard
}

/// A committed palette row and the window whose palette it came from.
///
/// Every main window's chrome receives the notification, so without the
/// window each one would run the row once. Only the window the palette
/// opened in runs it.
struct CommandPaletteExecution: Equatable {
    let action: CommandPaletteAction
    let windowID: WindowID
    /// Committed with ⌘ (⌘Return, ⌘-click): another project's row opens in
    /// a new window rather than switching this one. Only the
    /// supervision window reads it; any other row runs as it would without.
    var opensInNewWindow = false
}

@MainActor
enum CommandPaletteActions {
    /// ⌘P / ⌘⇧P — surface the palette in `windowID`. Idempotent: if it
    /// is already open there, focus it (the overlay observes
    /// `session.commandPaletteState` and grabs focus on the next render).
    /// Open in another window, it moves here, since the window that asks
    /// is the one the person is looking at.
    static func openCommandPalette( // swiftlint:disable:this function_parameter_count
        _ session: WorkspaceSession,
        in windowID: WindowID,
        settings: SettingsStore,
        frecencyStore: FrecencyStore,
        attention: AttentionState,
        registry: (any SurfaceViewProviding)? = nil,
        initialQuery: String = ">",
        // The window it opens in, as far as its rows' enabled states need it.
        supervision: SupervisionPaletteFacts
    ) {
        if session.commandPaletteState?.windowID == windowID {
            NotificationCenter.default.post(name: .weirCommandPaletteFocus, object: nil)
            return
        }
        let state = CommandPaletteState(locale: settings.appLocale, windowID: windowID)
        state.allItems = CommandPaletteCatalog.buildItems(
            session: session,
            settings: settings,
            attention: attention,
            registry: registry,
            supervision: supervision,
            window: windowID,
            locale: state.locale
        )
        state.initialQuery = initialQuery.isEmpty ? nil : initialQuery
        state.applyFilter(query: "", frecencyStore: frecencyStore)
        session.commandPaletteState = state
    }

    /// Dismiss the palette overlay. Routine — used by Esc, the
    /// outside-tap dismissal in `ToolbarPaletteField`, and the
    /// `executeCommandPaletteAction` finaliser below.
    static func closeCommandPalette(_ session: WorkspaceSession) {
        session.commandPaletteState = nil
    }

    /// Hands a committed row to the chrome of the window the palette is in,
    /// with whether ⌘ committed it (`CommandPaletteExecution.opensInNewWindow`).
    static func postExecution(
        of action: CommandPaletteAction,
        from state: CommandPaletteState,
        opensInNewWindow: Bool = false,
        commands: any WindowCommandPerforming
    ) {
        let execution = CommandPaletteExecution(action: action, windowID: state.windowID, opensInNewWindow: opensInNewWindow)
        commands.perform(.runPaletteRow(execution), in: state.windowID)
    }

    // swiftlint:disable function_parameter_count
    /// Run the palette row the user committed. Records the frecency
    /// hit so the next session sorts smarter, then routes to the
    /// matching domain action and pulls focus back to the terminal
    /// surface, except after a row the window ran placing the keyboard
    /// itself (`PaletteRowHandling.handled`).
    static func executeCommandPaletteAction(
        _ action: CommandPaletteAction,
        session: WorkspaceSession,
        attention: AttentionState,
        registry: any SurfaceViewProviding,
        commands: any WindowCommandPerforming,
        frecencyStore: FrecencyStore,
        toastCenter: ToastCenter,
        minPaneSize: PaneMinimumSize,
        agentProjection: AgentProjectionAdapter? = nil,
        window: WindowID,
        // The rows the window runs itself: the supervision window's session
        // rows, review tab, and close keys, as its menu runs them, and the
        // rows that go to another project.
        runsInWindow: (CommandPaletteAction) -> PaletteRowHandling = { _ in .notHandled }
    ) {
        // The palette closes whatever the row does: its state is the
        // session's one, and left open it would stand over the next window
        // to show it.
        closeCommandPalette(session)
        // A window the session does not know runs nothing: what was asked
        // of a window that is gone is not done in another.
        guard session.selection(window) != nil else { return }
        frecencyStore.record(action.frecencyKey)

        let handling = runsInWindow(action)
        // The window placed the keyboard itself: it moved it (a review tab
        // put in front, behind, or closed; another window brought to the
        // front), or the tab it switched to takes it as its surface mounts.
        // Pulling it back to the terminal here would undo the first.
        guard handling != .handled else { return }
        if handling == .notHandled {
            dispatch(
                action,
                session: session,
                attention: attention,
                registry: registry,
                commands: commands,
                window: window,
                toastCenter: toastCenter,
                minPaneSize: minPaneSize,
                agentProjection: agentProjection
            )
        }

        // Restore focus to the terminal surface so the next keystroke
        // lands on the pane the user was working in before the palette
        // intercepted the keyboard.
        if let tab = session.activeTab(in: window),
           let leafID = tab.splitTree.effectiveFocusedLeafID,
           let view = registry.view(for: leafID)
        {
            view.window?.makeFirstResponder(view)
        }
    }

    /// The shared dispatch of a committed row, in `window`.
    private static func dispatch(
        _ action: CommandPaletteAction,
        session: WorkspaceSession,
        attention: AttentionState,
        registry: any SurfaceViewProviding,
        commands: any WindowCommandPerforming,
        window: WindowID,
        toastCenter: ToastCenter,
        minPaneSize: PaneMinimumSize,
        agentProjection: AgentProjectionAdapter?
    ) {
        switch action {
        case let .shortcutAction(shortcut):
            TabActions.dispatchShortcutAction(
                shortcut,
                session: session,
                attention: attention,
                registry: registry,
                commands: commands,
                trackers: TabActions.SessionTrackers(
                    projection: agentProjection
                ),
                toastCenter: toastCenter,
                minPaneSize: minPaneSize,
                window: window
            )
        case let .jumpToTab(tabID):
            if let tab = session.tab(tabID) {
                session.setActiveContainer(tab.container, in: window, intent: .person)
                session.setActiveTab(tabID, in: window, intent: .person)
            }
        case let .activateProject(projectID):
            session.setActiveContainer(.project(projectID), in: window, intent: .person)
        case let .activateWorktree(pid, wid):
            session.setActiveContainer(.worktree(projectID: pid, worktreeID: wid), in: window, intent: .person)
        case let .reopenClosedTab(tabID):
            TabActions.reopenClosedTab(session, specificID: tabID, in: window, intent: .person)
        case let .openRecentProject(url):
            // Same flow as the sidebar's `+` menu. It finishes after the
            // focus restore below, and the new tab's surface takes focus
            // itself when it mounts.
            Task { @MainActor in
                await session.openProject(at: url, in: window, intent: .person)
            }
        case .openSettings:
            NotificationCenter.default.post(name: .weirOpenSettings, object: nil)
        case .openProjectSettings:
            commands.perform(.openProjectSettings(nil), in: window)
        case .closeProject:
            commands.perform(.closeProject(nil), in: window)
        case .restoreTurn:
            break // Run by the supervision window (`SupervisionWindowActions.runPaletteAction`).
        case .insertPrefix:
            break // Handled in ToolbarPaletteField, never reaches here.
        }
    }
    // swiftlint:enable function_parameter_count
}
