// ActiveTabChanges.swift
// Weir — which windows' selections moved since the last look, for their history and unread marks.

import Foundation
import WeirDomain

/// The windows whose (container, tab) moved since the last look, each with
/// where it was. `AppState.startActiveTabSync` records each move in that
/// window's own history and clears the unread marks of what it now shows.
///
/// The windows there at the start are where the restored session left
/// them, so their first move is history like any other. A window that
/// arrives later is handled once as it appears, as its initial change: it
/// records no history (there was nowhere to go back to) and flashes
/// nothing. So is a window that starts drawing its tab again without
/// moving (shown again, or handed the scratch tabs it had selected), once
/// its selection is settled: the look runs after whatever showed it chose
/// its tab, so one shown and moved at once is a move like any other. A
/// value so the rules are tested without the app.
struct ActiveTabChanges {
    struct Change: Equatable {
        let window: WindowID
        let isInitial: Bool
        /// Where the window was before this change.
        let previous: WorkspaceSession.NavTarget
    }

    private var lastTargets: [WindowID: WorkspaceSession.NavTarget]
    private var settledWindows: Set<WindowID>
    private var undrawnWindows: Set<WindowID>

    /// Starts from where each window is now, after the restore, and which
    /// draw nothing of it (`WorkspaceSession.undrawnWindowIDs`).
    init(current: [WindowID: WorkspaceSession.NavTarget], undrawn: Set<WindowID>) {
        lastTargets = current
        settledWindows = Set(current.keys)
        undrawnWindows = undrawn
    }

    /// The windows to handle given where each is now: those that moved,
    /// those that just arrived, and those that draw their tab again. A
    /// window that stayed put is left alone, so one window's move does
    /// nothing to another's history.
    mutating func changes(current: [WindowID: WorkspaceSession.NavTarget], undrawn: Set<WindowID>) -> [Change] {
        // A window that is gone is forgotten, so one coming back under its
        // ID starts afresh rather than from where the old one stood.
        lastTargets = lastTargets.filter { current[$0.key] != nil }
        settledWindows.formIntersection(current.keys)
        let drawnAgain = undrawnWindows.subtracting(undrawn)
        undrawnWindows = undrawn
        var changes: [Change] = []
        for (window, target) in current {
            let previous = lastTargets[window] ?? target
            let hasArrived = !settledWindows.contains(window)
            let isDrawnAgain = drawnAgain.contains(window)
            guard hasArrived || isDrawnAgain || previous != target else { continue }
            let isInitial = hasArrived || (isDrawnAgain && previous == target)
            changes.append(Change(window: window, isInitial: isInitial, previous: previous))
            lastTargets[window] = target
            settledWindows.insert(window)
        }
        return changes
    }
}
