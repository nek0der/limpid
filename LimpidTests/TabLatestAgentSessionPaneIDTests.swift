// TabLatestAgentSessionPaneIDTests.swift
// Limpid — the pane whose agent session started last, which a tab's agent title follows.

import Foundation
import Testing
@testable import Limpid

@Suite("Tab.latestAgentSessionPaneID")
struct TabLatestAgentSessionPaneIDTests {
    /// Date helper: a strict offset from a fixed epoch keeps the
    /// "older / newer" relation obvious in the test bodies.
    private func at(_ secondsFromEpoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: secondsFromEpoch)
    }

    /// A running agent's badge whose session started at `startedAt`.
    private func badge(startedAt: Date?) -> AgentBadge {
        AgentBadge(state: .running, updatedAt: at(0), sessionStartedAt: startedAt)
    }

    @Test("with no agents, the property is nil")
    func emptyTab_returnsNil() {
        let (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        #expect(tab.latestAgentSessionPaneID == nil)
    }

    @Test("the codex pane with the newer sessionStartedAt wins across two codex panes")
    func twoCodex_newerWins() {
        var (tab, pane1) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        let pane2 = UUID()
        tab.agentBadges[.codex] = [
            pane1: badge(startedAt: at(100)),
            pane2: badge(startedAt: at(200))
        ]
        #expect(tab.latestAgentSessionPaneID == pane2)
    }

    @Test("the latest pane wins across a mixed claude + codex pair")
    func mixedClaudeCodex_newerSessionWins() {
        var (tab, claudePane) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        let codexPane = UUID()
        tab.agentBadges[.claude] = [claudePane: badge(startedAt: at(300))]
        tab.agentBadges[.codex] = [codexPane: badge(startedAt: at(200))]
        #expect(tab.latestAgentSessionPaneID == claudePane)
    }

    @Test("a badge without sessionStartedAt is ignored")
    func badgeWithoutTimestamp_isSkipped() {
        var (tab, pane1) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        let pane2 = UUID()
        // Pre-migration badge (Limpid before this feature shipped) has
        // no captured timestamp — it must not be picked as the owner
        // just because the other pane also lacks one.
        tab.agentBadges[.codex] = [
            pane1: badge(startedAt: nil),
            pane2: badge(startedAt: at(50))
        ]
        #expect(tab.latestAgentSessionPaneID == pane2)
    }

    @Test("when every badge lacks a timestamp the property is nil")
    func allBadgesWithoutTimestamp_returnsNil() {
        var (tab, pane1) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        let pane2 = UUID()
        tab.agentBadges[.claude] = [pane1: badge(startedAt: nil)]
        tab.agentBadges[.codex] = [pane2: badge(startedAt: nil)]
        #expect(tab.latestAgentSessionPaneID == nil)
    }
}
