// MainWindowContent.swift
// Limpid — one main window's content: its root inside the shared chrome.

import SwiftUI

/// A main window's content, in the window an app-owned controller made
/// (`ProjectWindowPresenter`): its root with the overlays, sheets, and
/// alerts every main window carries (`WindowChromeHost`). It publishes its
/// window to menu commands and reports its visible panes as that window.
/// The controller bound the window's observers when it made the window.
struct MainWindowContent<Root: View>: View {
    let state: AppState
    let window: ProjectWindowState
    @ViewBuilder let root: (GhosttyApp) -> Root

    var body: some View {
        Group {
            if let app = state.ghosttyApp {
                root(app)
            } else {
                LibghosttyInitFailureView()
                    .environment(state)
            }
        }
        .ignoresSafeArea()
        .modifier(WindowChromeHost(state: state, window: window))
        .environment(\.paneVisibilityReporter, PaneVisibilityReporter(windowID: window.id, registry: state.windowRegistry))
        // The window's own state, for the views that act on this window
        // rather than the one with the keyboard (a sidebar row's click).
        .environment(window)
        // Its own review, so two windows never draw each other's.
        .environment(window.reviewPresentation)
        .environment(window.reviewTabDisplay)
        // Its own floating surfaces.
        .environment(window.prHover)
        .environment(window.paneRename)
        .environment(window.promptCachePanel)
        .environment(window.containerColor)
        .environment(window.notificationHistory)
    }
}
