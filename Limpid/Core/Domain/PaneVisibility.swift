// PaneVisibility.swift
// Limpid — which panes are on screen, per window, and across all of them.

import Foundation

/// The panes each window reports as on screen, and their union.
///
/// One pane's terminal is shown by at most one window at a time, but each
/// window learns only about its own: a window that is hidden or covered
/// knows its panes are not visible, not whether another window shows them.
/// So every window reports its own set, and a pane counts as visible when
/// any window says so. Taking the last report instead would let a window
/// going behind another stop the terminal that the front window still
/// shows.
struct PaneVisibility: Equatable, Sendable {
    private(set) var visibleByWindow: [WindowID: Set<UUID>] = [:]

    /// Replaces `window`'s set. An empty set removes the window, so a closed
    /// or hidden window leaves nothing behind.
    mutating func report(window: WindowID, visiblePaneIDs: Set<UUID>) {
        visibleByWindow[window] = visiblePaneIDs.isEmpty ? nil : visiblePaneIDs
    }

    var union: Set<UUID> {
        visibleByWindow.values.reduce(into: Set()) { $0.formUnion($1) }
    }
}
