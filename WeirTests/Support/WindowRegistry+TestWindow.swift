// WindowRegistry+TestWindow.swift
// Weir — windows no session stands behind, for suites that test a window's own state.

import Foundation
@testable import Weir

/// A window holds the selection the session keeps for it, and its views
/// read that one. Most suites that make a window test what the window
/// itself holds (its cursor, its decision bars, the panes it reports), with
/// no session behind it, so they make it on a selection of its own through
/// these. A suite whose window is one of a session's passes that session's
/// selection instead (`session.primarySelection`, `session.selection(id)`),
/// so the window reads what the session writes: one made here under a
/// session's window ID would read a selection the session never writes.
extension ProjectWindowState {
    convenience init(id: WindowID) {
        self.init(selection: WindowSelection(windowID: id))
    }
}

extension WindowRegistry {
    convenience init(primaryID: WindowID) {
        self.init(primary: WindowSelection(windowID: primaryID))
    }

    @discardableResult
    func addWindow(_ id: WindowID) -> ProjectWindowState {
        addWindow(WindowSelection(windowID: id))
    }
}
