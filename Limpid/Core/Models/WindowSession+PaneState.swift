// WindowSession+PaneState.swift
// Limpid — per-pane state mutators. Persisted bits (`unreadCount`,
// the pane's name) live on `Tab.paneStates`; transient bits (bell-ringing, child-exit
// code, and OSC 7 working directory) live on `WindowSession.paneTransients` so changing them
// doesn't churn the autosave hook. Both sets of verbs live here, plus
// the `tabID(forPane:)` lookup every mutator funnels through.

import Foundation

extension WindowSession {
    /// Tab containing the given pane id. Goes through a lazy
    /// paneID→tabID reverse index so libghostty event paths
    /// (focus, occlusion, action routing) stop paying O(N×L)
    /// per call. The cache stales out when which leaves each tab
    /// holds changes (see `paneIndexSignature`); on a miss we walk
    /// the tabs once, rebuild the dict, and proceed in O(1).
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

    /// Stale-marker for the reverse-index cache: a hash of which leaves
    /// each tab holds. It used to be the tab count plus the leaf count,
    /// which a move between two existing tabs leaves unchanged — merging a
    /// pane out of a two-pane tab into a one-pane tab keeps both totals —
    /// so the cache went on naming the pane's old tab, and every lookup
    /// through it read and wrote the wrong tab's state for that pane.
    /// Hashing the ids costs the same walk the counts did.
    private func paneIndexSignature() -> Int {
        var hasher = Hasher()
        for tab in tabs {
            hasher.combine(tab.id)
            for leaf in tab.splitTree.allLeafIDs() {
                hasher.combine(leaf)
            }
        }
        return hasher.finalize()
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

    /// Wipe unread counts across every pane in every tab. Called by the
    /// shared notification acknowledgement action so every "Mark All as
    /// Read" entry point clears the same window state.
    func clearAllUnread() {
        for tabIdx in tabs.indices {
            for (pid, state) in tabs[tabIdx].paneStates where state.unreadCount != 0 {
                tabs[tabIdx].paneStates[pid]?.unreadCount = 0
            }
        }
        cachedWindowUnreadCount = 0
    }

    /// Name a pane, or clear its name with nil or a blank string. Goes
    /// through `Tab.paneStates`, so the name autosaves with the session and
    /// follows the pane when it moves to another tab. A name equal to the
    /// stored one writes nothing, which keeps a no-op commit from
    /// scheduling a save.
    func renamePane(_ paneID: UUID, to name: String?) {
        let normalized = PaneHeaderRules.normalizedName(name)
        guard paneState(paneID).name != normalized else { return }
        mutatePane(paneID) { $0.name = normalized }
    }

    /// Apply a rename submitted from a pane header, in place or from the
    /// floating panel. `shownName` is the name the header showed when the
    /// edit began; `PaneHeaderRules.nameChange` decides what, if anything,
    /// that submit writes.
    func commitPaneRename(_ paneID: UUID, submitted: String, shownName: String) {
        let change = PaneHeaderRules.nameChange(
            submitted: submitted,
            stored: paneState(paneID).name,
            shown: shownName
        )
        switch change {
        case let .set(name): renamePane(paneID, to: name)
        case .clear: renamePane(paneID, to: nil)
        case nil: break
        }
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

    /// Record the latest OSC 7 working directory for one pane without making
    /// shell navigation part of the persisted session model.
    func setWorkingDirectory(paneID: UUID, path: String) {
        var t = paneTransients[paneID] ?? PaneTransients()
        guard t.workingDirectory != path else { return }
        t.workingDirectory = path
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

    /// Latest OSC 7 working directory reported by `paneID`, if any.
    func workingDirectory(paneID: UUID) -> String? {
        paneTransients[paneID]?.workingDirectory
    }

    /// Where a relative path printed in `paneID` is looked up, most specific
    /// first: the shell's current directory, the directory the tab opened
    /// in, then the container's root. An agent launched from the shell keeps
    /// the shell's directory, and agents print paths relative to the
    /// repository they work in, which the container root covers when the
    /// shell has moved elsewhere.
    func linkBaseDirectories(paneID: UUID) -> [URL] {
        let tab = tab(containing: paneID)
        let candidates: [URL?] = [
            workingDirectory(paneID: paneID).map { URL(fileURLWithPath: $0) },
            tab?.workingDirectory.map { URL(fileURLWithPath: $0) },
            tab.flatMap { rootDirectory(of: $0.container) }
        ]
        var seen: Set<String> = []
        return candidates.compactMap(\.self).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
