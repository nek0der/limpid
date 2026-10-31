// WorkspaceSession+Navigation.swift
// Weir — browser-style back/forward navigation history for the active (container, tab) pair.
//
// Stacks are transient (not persisted) and are mutated by:
//   * `AppState.startActiveTabSync` — every user-initiated jump records
//     the prior location via `recordNavigation`, which truncates the
//     forward stack to match browser semantics.
//   * Go Back / Go Forward (the menu bar, the palette) — call
//     `navigateBack` / `navigateForward`, which pop one stack and push
//     current onto the other.
//
// We detect "this jump came from a back/forward click" by checking
// whether `previous` sits on top of either stack — that's exactly the
// state `navigate*` leaves behind right before the observer fires.
// Using an `isNavigatingHistory` flag instead would race with the
// observer (`observeRepeatedly` schedules onChange via Task — async).

import Foundation
import WeirDomain

@MainActor
extension WorkspaceSession {
    /// Snapshot of "where the user is" used by back/forward navigation.
    /// Stored in the back/forward stacks and applied via
    /// `navigateBack` / `navigateForward`.
    struct NavTarget: Equatable {
        let container: ContainerID
        let tabID: UUID?
    }

    // Each window walks its own history (`WindowSelection.navBackStack`).
    // A window the session does not know has no place and no history.

    func currentNavTarget(in window: WindowID) -> NavTarget? {
        selection(window).map(NavTarget.init(at:))
    }

    func canNavigateBack(in window: WindowID) -> Bool {
        selection(window)?.navBackStack.isEmpty == false
    }

    func canNavigateForward(in window: WindowID) -> Bool {
        selection(window)?.navForwardStack.isEmpty == false
    }

    /// Push the prior nav target onto the back stack. Called by
    /// `AppState`'s activeTabID observer whenever a switch lands on a
    /// different (container, tab) pair. Truncates the forward stack —
    /// stepping off the history tail invalidates the redo chain, same
    /// as web browsers do.
    func recordNavigation(from previous: NavTarget, in window: WindowID) {
        guard let selection = selection(window),
              previous != currentNavTarget(in: window)
        else { return }
        if previous == selection.navBackStack.last {
            return
        }
        if previous == selection.navForwardStack.last {
            return
        }
        selection.navBackStack.append(previous)
        if selection.navBackStack.count > Self.navHistoryLimit {
            selection.navBackStack.removeFirst()
        }
        selection.navForwardStack.removeAll()
    }

    /// Pop the most recent prior target, push the current onto the
    /// forward stack, and switch. No-op if history is empty.
    func navigateBack(in window: WindowID, intent: SelectionIntent) {
        guard let selection = selection(window),
              let target = selection.navBackStack.popLast()
        else { return }
        selection.navForwardStack.append(NavTarget(at: selection))
        applyNavTarget(target, in: window, intent: intent)
    }

    func navigateForward(in window: WindowID, intent: SelectionIntent) {
        guard let selection = selection(window),
              let target = selection.navForwardStack.popLast()
        else { return }
        selection.navBackStack.append(NavTarget(at: selection))
        applyNavTarget(target, in: window, intent: intent)
    }

    private func applyNavTarget(_ target: NavTarget, in window: WindowID, intent: SelectionIntent) {
        if let tabID = target.tabID,
           tabs.contains(where: { $0.id == tabID })
        {
            setActiveTab(tabID, in: window, intent: intent)
        } else {
            setActiveContainer(target.container, in: window, intent: intent)
        }
    }

    /// Cap on how many "from where we came" entries we keep. Older
    /// entries fall off the front of `navBackStack`. Pulled out of the
    /// inline `> 100` so the limit is searchable + documented.
    private static let navHistoryLimit: Int = 100
}

@MainActor
extension WorkspaceSession.NavTarget {
    /// Where `selection` is now.
    init(at selection: WindowSelection) {
        self.init(container: selection.activeContainerID, tabID: selection.activeTabID)
    }
}
