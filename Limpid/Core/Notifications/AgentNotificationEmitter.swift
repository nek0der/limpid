// AgentNotificationEmitter.swift
// Limpid — raises the notification the rules asked for.
//
// The rules choose the moment, the wording under the title, and whether it
// interrupts. What is decided here is the part only this process knows: what
// the container is called, and how the entry is filed.

import Foundation

@MainActor
struct AgentNotificationEmitter {
    let kind: AgentKind
    let notificationManager: LimpidNotificationManager
    /// Background tmux panes are not visible merely because their client
    /// surface is focused. Those transitions still deserve a banner.
    var suppressWhenPaneFocused = true
    /// Nil for legacy pane-only notification producers.
    var runtimeID: String?
    /// Revision of the exact runtime event being delivered. Runtime IDs stay
    /// stable for an invocation, while this value advances for each turn.
    var eventToken: String?

    /// Raises the notification the rules decided on. What is decided here is
    /// the container label and the history kind. The container label beats
    /// the generic title because both agents set a generic terminal title, so
    /// the project or worktree path is the only thing that says which one
    /// finished.
    func deliver(_ payload: AgentNotifyPayload, tab: Tab, session: WindowSession) {
        let fallback = switch payload.kind {
        case .finished: kind.finishedTitle
        case .needsInput: kind.needsInputTitle
        case .failed: kind.errorTitle
        }
        let containerLabel = session.containerLabel(for: tab.container)
        let entryKind: NotificationEntry.Kind = switch payload.kind {
        case .finished: .agentFinished
        case .needsInput: .agentNeedsInput
        case .failed: .agentError
        }
        send(
            Delivery(
                title: containerLabel.isEmpty ? fallback : containerLabel,
                body: payload.body ?? fallback,
                kind: entryKind,
                presentsBanner: payload.presentsBanner
            ),
            tab: tab,
            paneID: payload.pane,
            session: session
        )
    }

    /// What one transition hands to the notification manager. Bundled
    /// so the per-state emitters differ only in how they fill it in.
    private struct Delivery {
        let title: String
        let body: String
        let kind: NotificationEntry.Kind
        var presentsBanner = true
    }

    private func send(
        _ delivery: Delivery,
        tab: Tab,
        paneID: UUID,
        session: WindowSession
    ) {
        notificationManager.send(
            title: delivery.title,
            body: delivery.body,
            paneID: paneID,
            tabID: tab.id,
            containerID: tab.container,
            requireFocus: suppressWhenPaneFocused,
            kind: delivery.kind,
            tabTitleSnapshot: tab.displayTitle,
            containerLabel: session.containerLabel(for: tab.container),
            runtimeID: runtimeID,
            eventToken: eventToken,
            presentsBanner: delivery.presentsBanner
        )
        // Agent events fire the macOS banner + history entry (above) but
        // deliberately do NOT bump the per-pane unread count that drives
        // the tab column/container column bell — an agent's attention surface is the lifecycle
        // badge + the Waiting list, not the bell. Routing them through
        // the bell too would double-signal the same event. The bell is
        // reserved for non-agent unread (terminal OSC 9/777, child-exit)
        // handled in GhosttyEventCoordinator.
    }

    /// Collapse whitespace + truncate to ~80 chars. Returns `nil` if
    /// the result would be empty so callers can fall back to a generic
    /// string. The macOS banner only shows a few lines anyway, so an
    /// 80-char window matches what the user actually sees.
    private static func truncatedPrompt(_ raw: String) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        let limit = 80
        if collapsed.count <= limit {
            return collapsed
        }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return collapsed[..<cutoff] + "…"
    }
}

extension AgentKind {
    /// macOS notification title used when a `(running|compacting) →
    /// finished` transition fires. The provider names itself through the
    /// registry, so adding one adds no string here; only the sentence around
    /// the name is translated.
    var finishedTitle: String {
        let name = AgentProviderRegistry.displayName(for: self)
        return String(localized: "\(name) finished", comment: "Notification title; the agent's name")
    }

    /// macOS notification title used when a pane transitions into
    /// `.needsInput` from any non-needsInput state.
    var needsInputTitle: String {
        let name = AgentProviderRegistry.displayName(for: self)
        return String(localized: "\(name) needs input", comment: "Notification title; the agent's name")
    }

    /// History-row title used when a pane transitions into `.error`
    /// and there is no container label to anchor on.
    var errorTitle: String {
        let name = AgentProviderRegistry.displayName(for: self)
        return String(localized: "\(name) hit an error", comment: "History row title; the agent's name")
    }
}
