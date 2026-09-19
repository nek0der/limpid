// QuitAgentPredicateTests.swift
// Limpid — which live agents make ⌘Q ask before quitting.

import Foundation
import Testing
@testable import Limpid

/// The predicate behind ⌘Q's `onlyWhenAgent` policy
/// (`AppState.shouldAllowQuit`). An agent in tmux outlives the quit, so it
/// alone must not make the dialog say work is at risk.
@Suite("Quit confirmation agents")
@MainActor
struct QuitAgentPredicateTests {
    /// One tab per badge, each on its own leaf.
    private func session(with badges: [(AgentKind, AgentBadge)]) -> WindowSession {
        let session = WindowSession()
        for (kind, badge) in badges {
            let tab = session.openTab(container: .loose)
            guard let leaf = tab.splitTree.allLeafIDs().first else { continue }
            session.update(tab.id) { $0.agentBadges[kind] = [leaf: badge] }
        }
        return session
    }

    private func badge(_ state: AgentState, isTmuxHosted: Bool?) -> AgentBadge {
        var badge = AgentBadge(state: state, updatedAt: Date())
        badge.isTmuxHosted = isTmuxHosted
        return badge
    }

    @Test func onlyAgentsInTmux_doNotAsk() {
        let session = session(with: [
            (.claude, badge(.running, isTmuxHosted: true)),
            (.codex, badge(.idle, isTmuxHosted: true))
        ])

        #expect(!session.hasAgentThatQuitWouldStop())
    }

    @Test func anAgentInAPane_asks_evenBesideOnesInTmux() {
        let session = session(with: [
            (.claude, badge(.running, isTmuxHosted: true)),
            (.codex, badge(.idle, isTmuxHosted: nil))
        ])

        #expect(session.hasAgentThatQuitWouldStop())
    }

    /// The rules clear the flag once the run's tmux is gone and its tab has
    /// become a terminal that resumes it; quitting would stop that one.
    @Test func anAgentWhoseTmuxIsGone_asks() {
        let session = session(with: [(.claude, badge(.running, isTmuxHosted: false))])

        #expect(session.hasAgentThatQuitWouldStop())
    }

    /// `.unknown` is no session at all, wherever it runs.
    @Test func aPaneWithNoSession_doesNotAsk() {
        let session = session(with: [(.claude, badge(.unknown, isTmuxHosted: nil))])

        #expect(!session.hasAgentThatQuitWouldStop())
    }
}
