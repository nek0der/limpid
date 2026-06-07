// WindowSession+PaneState.swift
// Limpid — per-pane state mutators. Persisted bits (`unreadCount`)
// live on `Tab.paneStates`; transient bits (bell-ringing, child-exit
// code) live on `WindowSession.paneTransients` so flipping them
// doesn't churn the autosave hook. Both sets of verbs live here, plus
// the `tabID(forPane:)` lookup every mutator funnels through.

import Foundation

extension WindowSession {
    /// Tab containing the given pane id. Goes through a lazy
    /// paneID→tabID reverse index so libghostty event paths
    /// (focus, occlusion, action routing) stop paying O(N×L)
    /// per call. The cache stales out when the (tabs × leaves)
    /// signature changes; on a miss we walk the tabs once,
    /// rebuild the dict, and proceed in O(1).
    func tab(containing paneID: UUID) -> Tab? {
        guard let tabID = tabID(forPane: paneID) else { return nil }
        return tabs.first { $0.id == tabID }
    }

    func tabID(forPane paneID: UUID) -> UUID? {
        let liveSignature = paneIndexSignature()
        if let cache = paneToTabIndexCache, cache.signature == liveSignature {
            return cache.map[paneID]
        }
        var map: [UUID: UUID] = [:]
        for tab in tabs {
            for leaf in tab.splitTree.allLeafIDs() {
                map[leaf] = tab.id
            }
        }
        paneToTabIndexCache = (liveSignature, map)
        return map[paneID]
    }

    /// Cheap stale-marker for the reverse-index cache. Adding or
    /// removing a tab changes `tabs.count`; splitting / closing a
    /// pane inside an existing tab changes the per-tab leaf count.
    /// Together they catch every mutation that can move a paneID
    /// between tabs.
    private func paneIndexSignature() -> Int {
        var sum = tabs.count
        for tab in tabs {
            sum &+= tab.splitTree.allLeafIDs().count
        }
        return sum
    }

    func paneState(_ paneID: UUID) -> PaneState {
        // Resolve through `tab(containing:)` instead of the two-step
        // `tabID(forPane:)` + `tabs.first(where:)` pair so we walk
        // the tabs at most once per call (the reverse-index handles
        // the rest).
        guard let tab = tab(containing: paneID) else { return PaneState() }
        return tab.paneStates[paneID] ?? PaneState()
    }

    @discardableResult
    private func mutatePane(_ paneID: UUID, _ transform: (inout PaneState) -> Void) -> Bool {
        guard let tab = tab(containing: paneID) else { return false }
        return update(tab.id) { tab in
            var state = tab.paneStates[paneID] ?? PaneState()
            transform(&state)
            tab.paneStates[paneID] = state
        }
    }

    func markUnread(paneID: UUID) {
        mutatePane(paneID) { $0.unreadCount += 1 }
        cachedWindowUnreadCount += 1
    }

    func clearUnread(paneID: UUID) {
        var dropped = 0
        mutatePane(paneID) { state in
            dropped = state.unreadCount
            guard state.unreadCount != 0 else { return }
            state.unreadCount = 0
        }
        cachedWindowUnreadCount = max(0, cachedWindowUnreadCount - dropped)
    }

    /// Wipe unread counts across every pane in every tab. Pairs with
    /// `NotificationHistoryStore.markAllRead()` for the toolbar
    /// ellipsis menu's "Mark All as Read".
    func clearAllUnread() {
        for tabIdx in tabs.indices {
            for (pid, state) in tabs[tabIdx].paneStates where state.unreadCount != 0 {
                tabs[tabIdx].paneStates[pid]?.unreadCount = 0
            }
        }
        cachedWindowUnreadCount = 0
    }

    /// Toggle the bell-ringing highlight for a pane. Writes through
    /// `paneTransients` so the mutation does NOT touch `tabs[idx]`
    /// and therefore does not trip the autosave observation hook.
    func setBell(paneID: UUID, ringing: Bool) {
        var t = paneTransients[paneID] ?? PaneTransients()
        guard t.isBellRinging != ringing else { return }
        t.isBellRinging = ringing
        paneTransients[paneID] = t
    }

    /// Stamp / clear the last-exit-code badge for a pane. Same
    /// rationale as `setBell` — transient, not autosave-worthy.
    func setChildExited(paneID: UUID, code: UInt32?) {
        var t = paneTransients[paneID] ?? PaneTransients()
        guard t.childExitCode != code else { return }
        t.childExitCode = code
        paneTransients[paneID] = t
    }

    // MARK: - Transient accessors (UI side)

    /// Bell ring state for `paneID`. Defaults to `false`.
    func isBellRinging(paneID: UUID) -> Bool {
        paneTransients[paneID]?.isBellRinging ?? false
    }

    /// Most recent child-exit code stamped on `paneID`, if any.
    func childExitCode(paneID: UUID) -> UInt32? {
        paneTransients[paneID]?.childExitCode
    }
}
