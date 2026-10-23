// AppState+SupervisionWindows.swift
// Limpid — hands every project window to app-owned controllers.

import AppKit
import SwiftUI

extension AppState {
    /// Called once from `LimpidApp.init`, before AppKit restores anything.
    ///
    /// No scene hosts a project window (`LimpidApp.body`), so from here the
    /// presenter opens the restored windows at launch and the last one when
    /// the Dock icon is clicked with every window hidden.
    func presentSupervisionWindows(updaterStack: UpdaterStack) {
        let presenter = ProjectWindowPresenter(
            session: session,
            registry: windowRegistry
        ) { [weak self] window in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                MainWindowContent(state: self, window: window) {
                    SupervisionWindowView(state: self, app: $0)
                }
                .limpidMainWindowEnvironment(self, updaterStack: updaterStack)
            )
        }
        windowRegistry.presenter = presenter
        // A hidden window draws nothing; shown again, it arrives at its
        // tab once its selection is settled (`startActiveTabSync`).
        windowRegistry.onVisibilityChange = { [weak self] window, isHidden in
            self?.session.setWindow(window, isHidden: isHidden)
        }
        windowRegistry.onKeyWindowChange = { [weak self] window in
            self?.session.frontWindowID = window
        }
        // A window shows one project at a time: the person's choice
        // of another project's session, however it is asked for, switches
        // the window in place, or brings forward the window that shows it.
        windowRegistry.connectProjectSwitching(of: session)
        // What a window switching in place holds for the project it
        // leaves goes: its panels, menus, rows' card, and decision bars.
        // The registry hands its review to that project.
        windowRegistry.onWillSwitchProject = { [weak self] window, from, _ in
            guard let self else { return }
            WindowProjectSwitch.tidy(window, leaving: from, session: session)
        }
        // The next project is settled before the window draws it: an open
        // panel keeps its layout through the switch, the sidebars being the
        // window's, and a closed one is worked out for the tab the switch
        // lands on, so it opens straight into its place
        // (`ChangesPanelLayoutRule.redecides`). Settled here rather than by
        // the view, so the scroll restore that follows counts the lists the
        // window draws.
        windowRegistry.onDidSwitchProject = { [weak self] window in
            guard let self else { return }
            window.followChangesPanelLayout(
                in: session,
                isAgentPane: { [attention] in attention.headerRuntime(inPane: $0) != nil },
                cellWidth: { [registry] in registry.view(for: $0)?.cellWidth }
            )
        }
        // A switch is drawn as one change with nothing animated: the
        // window's chrome stays, and what the next project shows replaces
        // what the last one did, rather than a panel sliding or the sidebar
        // fading between the two.
        windowRegistry.drawsSwitch = { switching in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, switching)
        }
        // With the switching connected, before anything asks for a
        // project's window: the restored windows are listed now and shown
        // at launch.
        windowRegistry.adoptWindows(of: session)
        gitFacts.start(session: session) { [weak self] in
            self?.windowRegistry.attention.isAppActive ?? false
        }
        observeRepeatedly { [weak self] in
            _ = self?.windowRegistry.attention.isAppActive
        } onChange: { [weak self] in
            guard let self else { return }
            gitFacts.appActivityChanged(isActive: windowRegistry.attention.isAppActive)
        }
        // However a window goes (its close button, ⌘W with nothing left to
        // close, ⇧⌘W, the Window menu), it goes through the registry
        // (`WindowRegistry.close`): the last window shown is hidden, and its
        // review goes with it, unless a comment is being written in it.
        windowRegistry.onHide = { [weak self] window in
            guard let self else { return }
            // Shown again, the window opens on its sessions, not on a panel
            // whose field no longer holds the keyboard.
            window.isAllProjectsPresented = false
            window.keyboardShortcuts.isPresented = false
            ReviewTabActions.windowHidden(
                window: window,
                session: session,
                registry: registry,
                paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: windowRegistry)
            )
        }
        // A removed project's kept review, and any new session sheet open
        // for it, go with it.
        observeRepeatedly { [weak self] in
            _ = self?.session.projects
        } onChange: { [weak self] in
            guard let self else { return }
            windowRegistry.forgetProjectsGone(in: session)
        }
        // Any other closes for real. A window left says what happened: the
        // sessions did not close with it.
        windowRegistry.onClose = { [weak self] window in
            guard let self else { return }
            WindowClosing.tidy(
                window,
                session: session,
                registry: windowRegistry,
                toasts: toastCenter
            )
        }
        LimpidAppDelegate.launchHandler = { [weak self] in
            guard let self else { return }
            windowRegistry.showRestoredWindows(of: session)
        }
        // A folder from Finder, `open -a`, or the Dock icon opens as ⌘O
        // opens one.
        LimpidAppDelegate.openHandler = { [weak self] urls in
            guard let self else { return }
            Task {
                await SupervisionWindowActions.openFolders(
                    urls,
                    session: session,
                    registry: windowRegistry,
                    frecency: frecencyStore
                )
            }
        }
        LimpidAppDelegate.reopenHandler = { [weak self] in
            guard let self else { return true }
            windowRegistry.showLastWindow()
            return false
        }
        // New Window, in the Dock menu as in the File menu: the hidden
        // window back, or a window that shows nothing.
        let dockMenu = NewWindowDockMenu(
            locale: { [weak self] in self?.settingsStore.appLocale ?? .current },
            open: { [weak self] in
                guard let self else { return }
                SupervisionWindowActions.newWindow(from: nil, session: session, registry: windowRegistry)
            }
        )
        LimpidAppDelegate.dockMenu = { dockMenu.makeMenu() }
    }
}
