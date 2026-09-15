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

    /// Replaces one provider's runtimes. The marks are not trimmed here: the
    /// projection returns the set that still applies with every pass, and the
    /// adapter writes that back, so trimming twice would be two rules for one
    /// thing.
    func replaceRuntimes(_ runtimes: [AgentRuntimePresentation], kind: AgentKind) {
        runtimesByKind[kind] = runtimes
    }

    func isViewed(_ runtime: AgentRuntimePresentation) -> Bool {
        viewedRuntimeTokens[runtime.id] == runtime.attentionEventToken
    }

    /// Explicit × or a viewed finished turn past `viewedFinishedRetention`.
    func isDismissed(_ runtime: AgentRuntimePresentation) -> Bool {
        if dismissedRuntimeTokens[runtime.id] == runtime.attentionEventToken {
            return true
        }
        return runtime.badge.state == .finished
            && isViewed(runtime)
            && isPastRetention(runtime.badge.updatedAt)
    }

    func dismissRuntime(_ id: String) {
        guard let runtime = allRuntimes.first(where: { $0.id == id }), runtime.badge.state == .finished else { return }
        dismissedRuntimeTokens[id] = runtime.attentionEventToken
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
                viewedRuntimeTokens[runtime.id] = runtime.attentionEventToken
                changed = true
            }
        }
        if changed {
            onRuntimeAttentionChanged?()
        }
    }

    /// Acknowledge finished runtime episodes recorded as read in notification
    /// history. Matching both identifiers prevents an old notification from
    /// acknowledging a later turn in the same invocation.
    func markFinishedRuntimesViewed(matching eventTokensByRuntimeID: [String: Set<String>]) {
        var changed = false
        for runtime in allRuntimes where runtime.badge.state == .finished {
            guard eventTokensByRuntimeID[runtime.id]?.contains(runtime.attentionEventToken) == true,
                  !isViewed(runtime)
            else { continue }
            viewedRuntimeTokens[runtime.id] = runtime.attentionEventToken
            changed = true
        }
        if changed {
            onRuntimeAttentionChanged?()
        }
    }
}
