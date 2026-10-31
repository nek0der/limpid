// ConversationTabsTests.swift
// Weir — the one mapping between a session's tabs and the conversations their panes run, split tabs included.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ConversationTabsTests {
    private static func key(_ id: String) -> ConversationKey {
        TurnSummaryFixture.conversation(id)
    }

    /// A session of two tabs, the second split in two.
    private struct Split {
        let session: WorkspaceSession
        /// The session's tabs, in order.
        let tabs: [Tab]
        /// The second tab's panes.
        let splitPanes: [UUID]
    }

    private static func session() throws -> Split {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let container = ContainerID.project(project.id)
        session.setActiveContainer(container)
        session.openTab(container: container)
        session.openTab(container: container)
        PaneActions.split(session, direction: .horizontal)
        let tabs = session.tabs(in: container)
        try #require(tabs.count == 2)
        let splitPanes = tabs[1].splitTree.allLeafIDs()
        try #require(splitPanes.count == 2)
        return Split(session: session, tabs: tabs, splitPanes: splitPanes)
    }

    /// Each conversation is placed at the first pane that runs it, in its
    /// tab's place from 1; a split tab runs both of its panes'
    /// conversations, in pane order.
    @Test func init_splitTab_mapsEveryPanesConversation() throws {
        let split = try Self.session()
        let tabs = split.tabs
        let splitPanes = split.splitPanes
        let firstPane = try #require(tabs[0].splitTree.allLeafIDs().first)
        let byPane = [firstPane: Self.key("a"), splitPanes[0]: Self.key("b"), splitPanes[1]: Self.key("c")]

        let mapping = ConversationTabs(tabs: tabs) { byPane[$0] }

        #expect(mapping.running == [Self.key("a"), Self.key("b"), Self.key("c")])
        #expect(mapping.conversations(of: tabs[1].id)?.all == [Self.key("b"), Self.key("c")])
        #expect(mapping.place(of: Self.key("c")) == ConversationTabs.Place(tabID: tabs[1].id, position: 2, paneID: splitPanes[1]))
        #expect(mapping.place(of: Self.key("a"))?.position == 1)
        #expect(mapping.place(of: Self.key("gone")) == nil)
    }

    /// A conversation in two panes is placed at the first, and listed once.
    @Test func init_conversationInTwoPanes_placedAtTheFirst() throws {
        let split = try Self.session()
        let tabs = split.tabs
        let splitPanes = split.splitPanes
        let byPane = [splitPanes[0]: Self.key("a"), splitPanes[1]: Self.key("a")]

        let mapping = ConversationTabs(tabs: tabs) { byPane[$0] }

        #expect(mapping.running == [Self.key("a")])
        #expect(mapping.conversations(of: tabs[1].id)?.all == [Self.key("a")])
        #expect(mapping.place(of: Self.key("a"))?.paneID == splitPanes[0])
    }

    /// The tab's title stands for the conversation in the pane its latest
    /// agent session started in, and for none while that pane runs none.
    @Test func init_titled_followsTheLatestSessionsPane() throws {
        let fixture = try Self.session()
        let session = fixture.session
        let tabs = fixture.tabs
        let splitPanes = fixture.splitPanes
        let started = { (seconds: TimeInterval) in
            AgentBadge(state: .running, updatedAt: Date(), sessionStartedAt: Date(timeIntervalSince1970: seconds))
        }
        session.update(tabs[1].id) { $0.agentBadges[.claude] = [splitPanes[0]: started(0), splitPanes[1]: started(60)] }
        let split = try #require(session.tab(tabs[1].id))
        try #require(split.latestAgentSessionPaneID == splitPanes[1])

        let titled = ConversationTabs(tabs: [split]) { [splitPanes[0]: Self.key("a"), splitPanes[1]: Self.key("b")][$0] }
        let untitled = ConversationTabs(tabs: [split]) { [splitPanes[0]: Self.key("a")][$0] }

        #expect(titled.conversations(of: split.id)?.titled == Self.key("b"))
        #expect(untitled.conversations(of: split.id)?.titled == nil)
        #expect(untitled.conversations(of: split.id)?.all == [Self.key("a")])
    }

    /// With no pane's session start known, a tab of one conversation still
    /// stands for it; a tab of two stands for neither, as the one its title
    /// follows is unknown.
    @Test func init_titled_noSessionStart_standsForTheOneConversation() throws {
        let fixture = try Self.session()
        let tabs = fixture.tabs
        let splitPanes = fixture.splitPanes
        let firstPane = try #require(tabs[0].splitTree.allLeafIDs().first)
        try #require(tabs.allSatisfy { $0.latestAgentSessionPaneID == nil })
        let byPane = [firstPane: Self.key("a"), splitPanes[0]: Self.key("b"), splitPanes[1]: Self.key("c")]

        let mapping = ConversationTabs(tabs: tabs) { byPane[$0] }

        #expect(mapping.conversations(of: tabs[0].id)?.titled == Self.key("a"))
        #expect(mapping.conversations(of: tabs[1].id)?.titled == nil)
    }
}
