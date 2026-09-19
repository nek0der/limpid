// QuitAgentPredicateTests.swift
// Limpid — which live agents make ⌘Q, and closing a tab or pane, ask first.

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

/// The predicate behind the close confirmation (`AppState.shouldAllowClose`).
/// Closing a tab or pane ends what runs in it, except an agent in tmux: the
/// server keeps it, and the Waiting list opens its tab again. Only an agent
/// the close would stop makes the dialog say one is active.
@Suite("Close confirmation agents")
@MainActor
struct CloseAgentPredicateTests {
    private func tab(in session: WindowSession, badge state: AgentState, isTmuxHosted: Bool?) -> [UUID] {
        let tab = session.openTab(container: .loose)
        let leaves = tab.splitTree.allLeafIDs()
        var badge = AgentBadge(state: state, updatedAt: Date())
        badge.isTmuxHosted = isTmuxHosted
        if let leaf = leaves.first {
            session.update(tab.id) { $0.agentBadges[.claude] = [leaf: badge] }
        }
        return leaves
    }

    @Test func anAgentInTmux_doesNotAsk() {
        let session = WindowSession()
        let leaves = tab(in: session, badge: .running, isTmuxHosted: true)

        #expect(!session.hasAgentThatClosingWouldStop(inAnyOf: leaves))
    }

    @Test func anAgentInThePane_asks() {
        let session = WindowSession()
        let leaves = tab(in: session, badge: .idle, isTmuxHosted: nil)

        #expect(session.hasAgentThatClosingWouldStop(inAnyOf: leaves))
    }

    /// Once its tmux is gone the tab is a terminal the agent resumed in, and
    /// closing it stops the agent.
    @Test func anAgentWhoseTmuxIsGone_asks() {
        let session = WindowSession()
        let leaves = tab(in: session, badge: .running, isTmuxHosted: false)

        #expect(session.hasAgentThatClosingWouldStop(inAnyOf: leaves))
    }

    /// Closing several tabs at once asks when any of them would stop an agent.
    @Test func closingSeveralTabs_asksForTheOneThatWouldStop() {
        let session = WindowSession()
        let hosted = tab(in: session, badge: .running, isTmuxHosted: true)
        let own = tab(in: session, badge: .running, isTmuxHosted: nil)

        #expect(!session.hasAgentThatClosingWouldStop(inAnyOf: hosted))
        #expect(session.hasAgentThatClosingWouldStop(inAnyOf: hosted + own))
    }
}
