// AttentionState+Runtimes.swift
// Limpid — invocation-scoped attention independent of client attachments.

import Foundation

extension AttentionState {
    func focusRuntime(_ id: String, in session: WindowSession, registry: any SurfaceViewProviding) -> Bool {
        guard let runtime = allRuntimes.first(where: { $0.id == id }),
              let paneID = runtime.paneIDs.sorted(by: { $0.uuidString < $1.uuidString })
              .first(where: { session.tab(containing: $0) != nil }),
              let tab = session.tab(containing: paneID)
        else { return false }
        focusAttention(in: session, registry: registry, tabID: tab.id, paneID: paneID, runtimeID: id)
        return true
    }

    var allRuntimes: [AgentRuntimePresentation] {
        runtimesByKind.values.flatMap(\.self)
    }

    func replaceRuntimes(_ runtimes: [AgentRuntimePresentation], kind: AgentKind) {
        runtimesByKind[kind] = runtimes
        let liveIDs = Set(allRuntimes.map(\.id))
        viewedRuntimeTokens = viewedRuntimeTokens.filter { liveIDs.contains($0.key) }
        dismissedRuntimeTokens = dismissedRuntimeTokens.filter { liveIDs.contains($0.key) }
    }

    func isViewed(_ runtime: AgentRuntimePresentation) -> Bool {
        viewedRuntimeTokens[runtime.id] == runtime.eventToken
    }

    func isDismissed(_ runtime: AgentRuntimePresentation) -> Bool {
        dismissedRuntimeTokens[runtime.id] == runtime.eventToken
    }

    func displayPriority(kind: AgentKind, runID: String, badge: AgentBadge) -> Int {
        guard badge.state == .finished,
              let runtime = runtimesByKind[kind]?.first(where: { $0.runID == runID })
        else { return badge.state.priority }
        if isDismissed(runtime) {
            return -1
        }
        return isViewed(runtime) ? 1 : badge.state.priority
    }

    func dismissRuntime(_ id: String) {
        guard let runtime = allRuntimes.first(where: { $0.id == id }), runtime.badge.state == .finished else { return }
        dismissedRuntimeTokens[id] = runtime.eventToken
        onRuntimeAttentionChanged?()
    }

    func markVisibleRuntimesViewed(paneID: UUID) {
        var changed = false
        for runtime in allRuntimes where runtime.paneIDs.contains(paneID) && runtime.badge.state == .finished {
            // Focusing the outer surface does not mean we saw a background
            // tmux pane. Only the active window's active pane is visible.
            if let location = runtime.tmuxLocations[paneID], !location.isActive {
                continue
            }
            if !isViewed(runtime) {
                viewedRuntimeTokens[runtime.id] = runtime.eventToken
                changed = true
            }
        }
        if changed {
            onRuntimeAttentionChanged?()
        }
    }
}
