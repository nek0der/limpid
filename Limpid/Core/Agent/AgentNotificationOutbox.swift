// AgentNotificationOutbox.swift
// Limpid — separates accepted lifecycle transitions from notification delivery.

import Foundation

struct AgentRunKey: Hashable {
    let kind: AgentKind
    let invocation: UUID
    var serialized: String {
        "\(kind.rawValue):\(invocation.uuidString)"
    }
}

struct AgentNotificationEventKey: Hashable {
    let run: AgentRunKey
    let revision: String
    let state: AgentState
}

struct AgentNotificationOutbox {
    static let pendingLifetime: TimeInterval = 5 * 60
    private struct Pending {
        let key: AgentNotificationEventKey
        let previous: AgentBadge?
        let createdAt: TimeInterval
    }

    private struct Observed {
        let badge: AgentBadge
        let attentionEventToken: String
    }

    private var previous: [AgentRunKey: Observed] = [:]
    private var pending: [AgentRunKey: Pending] = [:]

    mutating func observe(
        _ runtimes: [AgentRuntimePresentation], now: TimeInterval, isBootstrap: Bool = false
    ) -> [AgentRuntimeTransition] {
        let keys = Set(runtimes.compactMap(\.key))
        previous = previous.filter { keys.contains($0.key) }
        pending = pending.filter { keys.contains($0.key) && now - $0.value.createdAt < Self.pendingLifetime }
        if isBootstrap {
            pending.removeAll()
        }
        var ready: [AgentRuntimeTransition] = []
        for runtime in runtimes {
            guard let key = runtime.key else { continue }
            let priorObservation = previous[key]
            let prior = priorObservation?.badge
            previous[key] = Observed(
                badge: runtime.badge,
                attentionEventToken: runtime.attentionEventToken
            )
            if isBootstrap {
                continue
            }
            if let event = pending[key], event.key.state != runtime.badge.state {
                pending[key] = nil
            }
            let beginsAttentionEpisode = (runtime.badge.state == .needsInput || runtime.badge.state == .error)
                && priorObservation?.attentionEventToken != runtime.attentionEventToken
            if beginsAttentionEpisode || AgentRuntimeTransition.isNotifiable(previous: prior, current: runtime.badge) {
                pending[key] = Pending(
                    key: AgentNotificationEventKey(run: key, revision: runtime.eventToken, state: runtime.badge.state),
                    // Same-state snapshots can conceal an intervening
                    // running state. Nil lets the emitter announce the
                    // new persisted attention episode in that case.
                    previous: beginsAttentionEpisode ? nil : prior,
                    createdAt: now
                )
            }
            switch runtime.resolution {
            case .detached: pending[key] = nil
            case .unresolved: break
            case .attached:
                if let event = pending[key], !runtime.paneIDs.isEmpty {
                    ready.append(AgentRuntimeTransition(runtime: runtime, previous: event.previous, eventRevision: event.key.revision))
                }
            }
        }
        return ready.sorted { $0.runtime.id < $1.runtime.id }
    }

    mutating func acknowledge(_ event: AgentRuntimeTransition) {
        guard let key = event.runtime.key, let pendingEvent = pending[key],
              pendingEvent.key.revision == (event.eventRevision ?? event.runtime.eventToken),
              pendingEvent.key.state == event.runtime.badge.state
        else { return }
        pending[key] = nil
    }
}
