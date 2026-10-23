// TurnHistory.swift
// Limpid — every recorded turn, by conversation, as the last projection pass read them.

import Foundation
import Observation

/// The recorded turns of every conversation the hooks have written.
///
/// Replaced whole when a projection pass reports the turns (it leaves them
/// out when no turn and no run changed), and left as it was by one that
/// fails, like the runtimes. Views read a conversation's turns here by the
/// key a runtime carries (`AgentRuntimePresentation.conversation`).
@MainActor
@Observable
final class TurnHistory {
    /// Each conversation's turns, in display order.
    private(set) var conversations: [ConversationKey: [TurnSummary]] = [:]
    /// Whether a pass has reported the turns once. Before then an empty
    /// history says nothing about which turns are unread.
    private(set) var hasLoaded = false
    /// Counts each change of `conversations`, so a value derived from the
    /// whole history (`AppState.restoredTurnIDs`) is worked out again only
    /// when it changes, without comparing every turn to tell.
    private(set) var revision = 0

    /// Runs `body` once a pass has reported the turns: at once when one
    /// has, else on the first.
    func whenLoaded(_ body: @escaping @MainActor () -> Void) {
        if hasLoaded {
            body()
            return
        }
        withObservationTracking {
            _ = hasLoaded
        } onChange: { [weak self] in
            Task { @MainActor in self?.whenLoaded(body) }
        }
    }

    func replace(with list: [ConversationTurns]) {
        if !hasLoaded {
            hasLoaded = true
        }
        let next = Dictionary(list.map { ($0.key, $0.turns) }, uniquingKeysWith: { first, _ in first })
        // Assigned only on a change, so a pass that read nothing new does not
        // invalidate every view that reads a conversation.
        if next != conversations {
            conversations = next
            revision &+= 1
        }
    }

    /// `key`'s turns, in display order; empty when it has none.
    func turns(of key: ConversationKey) -> [TurnSummary] {
        conversations[key] ?? []
    }

    /// The turn with `id`, in whichever conversation it is.
    func turn(_ id: TurnID) -> TurnSummary? {
        for turns in conversations.values {
            if let turn = turns.first(where: { $0.turnID == id }) {
                return turn
            }
        }
        return nil
    }
}
