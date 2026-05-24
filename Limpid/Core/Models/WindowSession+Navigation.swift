// WindowSession+Navigation.swift
// Limpid — VS Code-style back/forward navigation history for the
// active (container, tab) pair. Stacks are transient (not persisted)
// and are mutated by:
//   * `AppState.startActiveTabSync` — every user-initiated jump records
//     the prior location via `recordNavigation`, which truncates the
//     forward stack to match browser/VS Code semantics.
//   * The L3 chrome `< / >` buttons — call `navigateBack` /
//     `navigateForward`, which pop one stack and push current onto
//     the other.
//
// We detect "this jump came from a back/forward click" by checking
// whether `previous` sits on top of either stack — that's exactly the
// state `navigate*` leaves behind right before the observer fires.
// Using an `isNavigatingHistory` flag instead would race with the
// observer (`observeRepeatedly` schedules onChange via Task — async).

import Foundation

@MainActor
extension WindowSession {
    /// Snapshot of "where the user is" used by back/forward navigation.
    /// Stored in the back/forward stacks and applied via
    /// `navigateBack` / `navigateForward`.
    struct NavTarget: Equatable {
        let container: ContainerID
        let tabID: UUID?
    }

    var currentNavTarget: NavTarget {
        NavTarget(container: activeContainerID, tabID: activeTabID)
    }

    var canNavigateBack: Bool {
        !navBackStack.isEmpty
    }

    var canNavigateForward: Bool {
        !navForwardStack.isEmpty
    }

    /// Push the prior nav target onto the back stack. Called by
    /// `AppState`'s activeTabID observer whenever a switch lands on a
    /// different (container, tab) pair. Truncates the forward stack —
    /// stepping off the history tail invalidates the redo chain, same
    /// as browsers / VS Code.
    func recordNavigation(from previous: NavTarget) {
        guard previous != currentNavTarget else { return }
        if previous == navBackStack.last { return }
        if previous == navForwardStack.last { return }
        navBackStack.append(previous)
        if navBackStack.count > Self.navHistoryLimit {
            navBackStack.removeFirst()
        }
        navForwardStack.removeAll()
    }

    /// Pop the most recent prior target, push the current onto the
    /// forward stack, and switch. No-op if history is empty.
    func navigateBack() {
        guard let target = navBackStack.popLast() else { return }
        navForwardStack.append(currentNavTarget)
        applyNavTarget(target)
    }

    func navigateForward() {
        guard let target = navForwardStack.popLast() else { return }
        navBackStack.append(currentNavTarget)
        applyNavTarget(target)
    }

    private func applyNavTarget(_ target: NavTarget) {
        if let tabID = target.tabID,
           tabs.contains(where: { $0.id == tabID })
        {
            setActiveTab(tabID)
        } else {
            setActiveContainer(target.container)
        }
    }

    /// Cap on how many "from where I came" entries we keep. Older
    /// entries fall off the front of `navBackStack`. Pulled out of the
    /// inline `> 100` so the limit is searchable + documented.
    private static let navHistoryLimit: Int = 100
}
