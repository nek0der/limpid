// TabAgentTitleTests.swift
// Limpid — pure-data tests for the agent-title pieces threaded across
// `Tab.latestAgentSessionPaneID`, the Codex tracker's title selector,
// and the OSC 2 gate in `GhosttyEventCoordinator`. The selector
// implementation lives off `Tab`'s badge dicts; we drive it here with
// raw badges so we don't need to spin up FSEvents / hook scripts.

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

    private func codexBadge(startedAt: Date?, firstPrompt: String? = nil) -> CodexAgentBadge {
        CodexAgentBadge(
            state: .running,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: at(0),
            lastPrompt: nil,
            firstPrompt: firstPrompt,
            sessionStartedAt: startedAt
        )
    }

    private func claudeBadge(startedAt: Date?) -> ClaudeAgentBadge {
        ClaudeAgentBadge(
            state: .running,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: at(0),
            lastPrompt: nil,
            sessionStartedAt: startedAt
        )
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
        tab.codexAgentBadges = [
            pane1: codexBadge(startedAt: at(100)),
            pane2: codexBadge(startedAt: at(200))
        ]
        #expect(tab.latestAgentSessionPaneID == pane2)
    }

    @Test("the latest pane wins across a mixed claude + codex pair")
    func mixedClaudeCodex_newerSessionWins() {
        var (tab, claudePane) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        let codexPane = UUID()
        tab.claudeAgentBadges = [claudePane: claudeBadge(startedAt: at(300))]
        tab.codexAgentBadges = [codexPane: codexBadge(startedAt: at(200))]
        #expect(tab.latestAgentSessionPaneID == claudePane)
    }

    @Test("a badge without sessionStartedAt is ignored")
    func badgeWithoutTimestamp_isSkipped() {
        var (tab, pane1) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        let pane2 = UUID()
        // Pre-migration badge (Limpid before this feature shipped) has
        // no captured timestamp — it must not be picked as the owner
        // just because the other pane also lacks one.
        tab.codexAgentBadges = [
            pane1: codexBadge(startedAt: nil),
            pane2: codexBadge(startedAt: at(50))
        ]
        #expect(tab.latestAgentSessionPaneID == pane2)
    }

    @Test("when every badge lacks a timestamp the property is nil")
    func allBadgesWithoutTimestamp_returnsNil() {
        var (tab, pane1) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        let pane2 = UUID()
        tab.claudeAgentBadges = [pane1: claudeBadge(startedAt: nil)]
        tab.codexAgentBadges = [pane2: codexBadge(startedAt: nil)]
        #expect(tab.latestAgentSessionPaneID == nil)
    }
}
