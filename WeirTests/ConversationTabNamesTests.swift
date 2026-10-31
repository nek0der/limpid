// ConversationTabNamesTests.swift
// Weir — the name the person gave a tab stays with the conversation it stood for, past the tab and across a relaunch.

import Foundation
import Testing
@testable import Weir

@MainActor
struct ConversationTabNamesTests {
    private static let conversation = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)

    /// A loose tab whose one pane runs `conversation`, and the run that
    /// says so.
    private struct Running {
        let session: WorkspaceSession
        let tab: Tab
        let runtimes: [AgentRuntimePresentation]
    }

    /// `Running` with the run in `state`.
    private static func tabRunningConversation(_ state: AgentState = .running) -> Running {
        let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
        let runtime = AgentRuntimePresentation.test(
            badge: AgentBadge(state: state, updatedAt: Date(), conversationID: "c1"),
            paneIDs: [paneID],
            conversation: conversation
        )
        return Running(session: session, tab: tab, runtimes: [runtime])
    }

    /// Renaming a tab names the conversation its title stands for, and
    /// clearing the name gives the conversation back to its agent's title.
    @Test func renameTab_keepsTheNameForTheConversation_andClearingLetsItGo() {
        let running = Self.tabRunningConversation()
        let (session, tab, runtimes) = (running.session, running.tab, running.runtimes)

        session.renameTab(tab.id, to: "Payments", runtimes: runtimes)
        #expect(session.conversationTabNames == [Self.conversation: "Payments"])

        session.renameTab(tab.id, to: "", runtimes: runtimes)
        #expect(session.conversationTabNames.isEmpty)
    }

    /// The name outlives the tab's run: once no agent runs in the tab, a
    /// new name for it is the tab's alone.
    @Test func renameTab_afterTheRunEnds_keepsTheConversationsName() {
        let running = Self.tabRunningConversation()
        let (session, tab, runtimes) = (running.session, running.tab, running.runtimes)
        session.renameTab(tab.id, to: "Payments", runtimes: runtimes)

        session.renameTab(tab.id, to: "Other", runtimes: [])

        #expect(session.conversationTabNames == [Self.conversation: "Payments"])
    }

    /// A tab whose agent has ended reads as a shell's, as the strip and the
    /// panel read it, even while the ended run's badge is still on its pane:
    /// renaming it to reuse it does not rename the ended conversation.
    @Test func renameTab_endedAgent_namesNoConversation() {
        let running = Self.tabRunningConversation(.unknown)
        let (session, tab, runtimes) = (running.session, running.tab, running.runtimes)

        session.renameTab(tab.id, to: "Reused", runtimes: runtimes)

        #expect(session.conversationTabNames.isEmpty)
    }

    /// Clearing a row's name that came from its tab clears the tab's name
    /// as the person clearing it on the tab would, so the conversation the
    /// tab stands for lets go of it too.
    @Test func renameRow_clearingTheTabsName_letsTheConversationsNameGo() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let container = ContainerID.project(project.id)
        let tab = session.openTab(container: container)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let runtimes = [AgentRuntimePresentation.test(
            badge: AgentBadge(state: .running, updatedAt: Date(), conversationID: "c1"),
            paneIDs: [pane],
            conversation: Self.conversation
        )]
        session.renameTab(tab.id, to: "Payments", runtimes: runtimes)
        try #require(session.conversationTabNames == [Self.conversation: "Payments"])

        session.renameRow(container, to: "", runtimes: runtimes)

        #expect(session.tab(tab.id)?.titleOverride == nil)
        #expect(session.conversationTabNames.isEmpty)
    }

    /// The names are saved at the root of `state.json` and read back; a
    /// file from before them reads as none.
    @Test func snapshot_conversationTabNames_roundTrip() throws {
        let running = Self.tabRunningConversation()
        let (session, tab, runtimes) = (running.session, running.tab, running.runtimes)
        session.renameTab(tab.id, to: "Payments", runtimes: runtimes)

        let data = try JSONEncoder().encode(session.makeSnapshot())
        let restored = WorkspaceSession()
        try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))
        #expect(restored.conversationTabNames == [Self.conversation: "Payments"])

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["conversationTabNames"] = nil
        let older = WorkspaceSession()
        try older.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))
        #expect(older.conversationTabNames.isEmpty)
    }

    /// One name that does not read costs only itself.
    @Test func snapshot_unreadableName_isPassedOver() throws {
        let running = Self.tabRunningConversation()
        let (session, tab, runtimes) = (running.session, running.tab, running.runtimes)
        session.renameTab(tab.id, to: "Payments", runtimes: runtimes)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session.makeSnapshot())) as? [String: Any])
        var names = try #require(object["conversationTabNames"] as? [Any])
        names.append(["name": 3])
        object["conversationTabNames"] = names

        let restored = WorkspaceSession()
        try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))

        #expect(restored.conversationTabNames == [Self.conversation: "Payments"])
    }
}
