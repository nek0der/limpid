// AgentProjectionAdapter+Demo.swift
// Limpid — stands the demo fixture's badges and turns in for what a pass would report.

import Foundation

/// What demo mode shows in place of a projection pass: the turns it
/// stages, the conversation each staged agent's pane runs, and how far each
/// conversation was viewed. The app hands it in (`AppState`), so the adapter
/// and the viewed-line store read no fixture themselves.
struct StagedProjection {
    let turns: [ConversationTurns]
    let conversation: (UUID) -> ConversationKey?
    /// The last viewed turn of each conversation, by display number: the
    /// changes panel draws its viewed line there, and only the turns after
    /// it are unread.
    var viewedThrough: [ConversationKey: Int] = [:]

    /// Moves each staged conversation's viewed line below its last viewed
    /// turn. The store is the demo run's, which keeps its lines in memory and
    /// moves no ref (`ViewedLineStore.writesFiles`).
    @MainActor
    func markViewedLines(in store: ViewedLineStore) {
        for conversation in turns {
            guard let number = viewedThrough[conversation.key],
                  let turn = conversation.turns.first(where: { $0.displayNumber == number })
            else { continue }
            // As if the person had pressed Mark as Viewed on the decision bar
            // an earlier session showed.
            store.markViewed(through: turn, source: .decisionBar)
        }
    }
}

extension AgentProjectionAdapter {
    /// What demo mode shows in place of the passes it never runs: runtimes
    /// standing in for the fixture's badges, and the staged turns.
    func show(_ staged: StagedProjection?, in session: WorkspaceSession, attention: AttentionState?) {
        if let attention {
            Self.seedRuntimes(fromBadgesIn: session, into: attention, conversation: staged?.conversation ?? { _ in nil })
        }
        if let staged {
            turnHistory.replace(with: staged.turns)
        }
    }

    /// Demo mode never runs a pass, so the runtimes the attention list and the
    /// row badges read would stay empty and the fixture's staged turns would
    /// show nowhere. The fixture stages badges, and those are enough to stand
    /// in for runtimes: one per badge, keyed by its pane so the identity is
    /// stable across launches, which is what `make screenshot` depends on. A
    /// pane the fixture stages a conversation for carries it, so its turns show
    /// as a real run's would (`StagedProjection`).
    static func seedRuntimes(
        fromBadgesIn session: WorkspaceSession,
        into attention: AttentionState,
        conversation: (UUID) -> ConversationKey? = { _ in nil }
    ) {
        for kind in AgentKind.allCases {
            var runtimes: [AgentRuntimePresentation] = []
            for tab in session.tabs {
                for (pane, badge) in tab.agentBadges[kind] ?? [:] {
                    runtimes.append(AgentRuntimePresentation(
                        kind: kind,
                        runID: pane.uuidString,
                        revision: nil,
                        badge: badge,
                        paneIDs: [pane],
                        tmuxLocations: [:],
                        stateEpisodeToken: "\(pane.uuidString):\(badge.updatedAt.timeIntervalSince1970)",
                        attachmentResolution: .attached,
                        conversation: conversation(pane)
                    ))
                }
            }
            attention.replaceRuntimes(runtimes, kind: kind)
        }
    }
}
