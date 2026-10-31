// TitleBarHistoryModel.swift
// Weir — whether the title bar's back and forward buttons can be pressed in a window.

/// The title bar's back and forward buttons as one window has them:
/// each can be pressed while its side of the window's own history has a
/// place, as Go Back and Go Forward in the menu can
/// (`WorkspaceSession.canNavigateBack(in:)`). Read through the session so
/// a view that builds it each body observes the window's history stacks
/// and turns the buttons on and off as they change.
@MainActor
struct TitleBarHistoryModel: Equatable {
    let canGoBack: Bool
    let canGoForward: Bool

    init(session: WorkspaceSession, window: WindowID) {
        canGoBack = session.canNavigateBack(in: window)
        canGoForward = session.canNavigateForward(in: window)
    }
}
