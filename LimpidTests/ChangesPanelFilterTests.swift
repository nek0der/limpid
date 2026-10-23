// ChangesPanelFilterTests.swift
// Limpid — the panel's filter and the rail read apart from the rows: where each conversation runs, and the rail's count and breakdown.

import Foundation
import Testing
@testable import Limpid

@Suite("Changes panel filter and rail")
struct ChangesPanelFilterTests {
    private typealias Panel = ChangesPanelFixture

    @Test func theFilter_saysWhichTabRunsEachConversation() throws {
        var other = TurnSummaryFixture.Extras()
        other.conversationID = "s2"
        let live = try [Panel.turn(1)]
        let ended = try [Panel.turn(1, extras: other)]
        let tab = ConversationChoice.LiveTab(title: "claude", isInSession: true)
        var input = Panel.input([Panel.agent(live), Panel.agent(ended)], running: [live[0].conversation])
        input.liveTab = { $0 == live[0].conversation ? tab : nil }

        let list = try Panel.list(ChangesPanelModel.make(input))

        #expect(list.conversations.map(\.liveTab) == [tab, nil], "the one a pane runs, named by its tab")
        #expect(list.conversations.map(\.isRunningHere) == [true, false])
        #expect(list.conversations.map(\.section) == [.running, .unviewed])
    }

    @Test func theFilterListsEveryConversation_whileTheRailsBreakdownListsThoseWithSomethingToRead() throws {
        var second = TurnSummaryFixture.Extras()
        second.conversationID = "s2"
        var third = TurnSummaryFixture.Extras()
        third.conversationID = "s3"
        let first = try [Panel.turn(1), Panel.turn(2)]
        let other = try [Panel.turn(1, extras: second)]
        let viewed = try [Panel.turn(1, extras: third)]
        let agents = [Panel.agent(first), Panel.agent(other), Panel.agent(viewed)]
        var input = Panel.input(
            agents,
            lines: [Panel.line(through: viewed[0]).line],
            chosen: other[0].conversation,
            running: [viewed[0].conversation]
        )
        input.liveTab = { $0 == viewed[0].conversation ? ConversationChoice.LiveTab(title: "claude", isInSession: true) : nil }

        let list = try Panel.list(ChangesPanelModel.make(input))
        let rail = ChangesPanelModel.rail(input)

        #expect(list.conversations.map(\.conversation) == agents.map(\.conversation), "every conversation, viewed ones too")
        #expect(list.conversations.map(\.section) == [.unviewed, .unviewed, .running])
        #expect(
            rail.agents.map(\.conversation) == [first[0].conversation, other[0].conversation],
            "the conversations with turns to read, not the viewed one a pane runs"
        )
        #expect(rail.agents.map(\.ordinal) == [1, 2], "named among every conversation of the kind")
        #expect(rail.unviewed == 3)
        #expect(rail.agents.map(\.unviewedCount).reduce(0, +) == rail.unviewed, "the breakdown adds up to the badge")
        #expect(ChangesPanelModel.unviewedTotal(input) == 3)

        let alone = Panel.input([Panel.agent(first)])
        #expect(ChangesPanelModel.rail(alone).unviewed == 2, "one agent: a count with no breakdown")
        #expect(ChangesPanelModel.rail(alone).agents.isEmpty)
        let read = ChangesPanelModel.rail(Panel.input([Panel.agent(viewed)], lines: [Panel.line(through: viewed[0]).line]))
        #expect(read.unviewed == 0)
        #expect(read.agents.isEmpty, "nothing to break down")
    }

    /// Each entry carries what its latest turn was asked and when it last
    /// did something: its latest turn's end, or its start while it runs.
    @Test func eachEntry_carriesItsLatestPromptAndActivity() throws {
        func turn(_ number: Int, of conversation: String, start: String, end: String?, prompt: String) throws -> TurnSummary {
            var extras = TurnSummaryFixture.Extras()
            extras.conversationID = conversation
            extras.startedAt = start
            extras.finishedAt = end
            extras.promptHead = prompt
            return try TurnSummaryFixture.turn(
                "T\(number)-\(conversation)",
                changes: TurnSummaryFixture.changedFiles,
                number: number,
                extras: extras
            )
        }
        let ended = try [
            turn(1, of: "s1", start: "2026-10-12T10:00:00Z", end: "2026-10-12T10:05:00Z", prompt: "Add the setting"),
            turn(2, of: "s1", start: "2026-10-12T10:20:00Z", end: "2026-10-12T10:30:00Z", prompt: "Save the order")
        ]
        let running = try [turn(1, of: "s2", start: "2026-10-12T10:40:00Z", end: nil, prompt: "Fix the README")]

        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent(ended), Panel.agent(running)])))

        #expect(list.conversations.map(\.latestPrompt?.head) == ["Save the order", "Fix the README"])
        #expect(list.conversations.map(\.lastActivity) == [
            UnreadTurnRules.date("2026-10-12T10:30:00Z"),
            UnreadTurnRules.date("2026-10-12T10:40:00Z")
        ])
        #expect(ConversationChoice.byLatestActivity(list.conversations).map(\.conversation) == [
            running[0].conversation,
            ended[0].conversation
        ])
    }

    @Test func aConversationRunElsewhere_isRunningButNotHere() {
        let away = ConversationChoice.LiveTab(title: "claude", isInSession: false, checkoutPlace: .named("beta"))
        let choice = ConversationChoice(
            conversation: TurnSummaryFixture.conversation,
            ordinal: 1,
            unviewedCount: 0,
            liveTab: away
        )

        #expect(!choice.isRunningHere, "the panel's running counts this session's panes alone")
        #expect(choice.liveTab != nil, "not ended")
        #expect(choice.section == .viewed, "listed as viewed, said to run elsewhere")
    }

    @Test func theTabRunningAConversation_isTheSessionsFirst_thenAnyOther() {
        let here = TurnSummaryFixture.conversation("here")
        let twice = TurnSummaryFixture.conversation("twice")
        let both = TurnSummaryFixture.conversation("both")
        let away = TurnSummaryFixture.conversation("away")
        let untitled = TurnSummaryFixture.conversation("untitled")
        typealias Tab = ConversationChoice.LiveTab
        func pane(_ conversation: ConversationKey?, _ tab: Tab) -> ChangesPanelModel.LivePane {
            ChangesPanelModel.LivePane(conversation: conversation, tab: tab)
        }
        let scratch = Tab(title: "scratch", isInSession: false)
        let panes = [
            // Another workspace's tab before the session's, in the tabs' order.
            pane(both, scratch),
            pane(away, scratch),
            pane(nil, Tab(title: "zsh", isInSession: true)),
            pane(here, Tab(title: "claude", isInSession: true)),
            pane(twice, Tab(title: "first", isInSession: true)),
            pane(twice, Tab(title: "second", isInSession: true)),
            pane(both, Tab(title: "beside", isInSession: true)),
            pane(untitled, Tab(title: "", isInSession: true))
        ]

        let tabs = ChangesPanelModel.liveTabs(panes)

        #expect(tabs[here]?.title == "claude")
        #expect(tabs[twice]?.title == "first", "the first pane in the tabs' order")
        #expect(tabs[both] == Tab(title: "beside", isInSession: true), "the session's own tab over another workspace's")
        #expect(tabs[away] == scratch, "run only in another workspace: running, not ended, and said to be elsewhere")
        #expect(tabs[untitled]?.title == "", "running in a tab with no title yet")
        #expect(tabs[TurnSummaryFixture.conversation("gone")] == nil, "no pane of the app runs it")
        #expect(tabs.count == 5, "a pane with no agent names nothing")
    }
}
