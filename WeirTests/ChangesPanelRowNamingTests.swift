// ChangesPanelRowNamingTests.swift
// Weir — the changes panel's conversation names and its restore entries on timeline rows.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

extension ChangesPanelModelTests {

    // MARK: - Every conversation, named

    /// The review's scope menu and destination menu name each conversation
    /// as the panel does: numbered among every conversation of the kind in
    /// the worktree, ended and viewed ones too, and by its kind alone where
    /// it is the one of its kind.
    @Test func everyConversation_isNamedAmongEveryOneOfItsKind() throws {
        var extras = TurnSummaryFixture.Extras()
        let turns = try ["first", "second", "third"].map { id in
            extras.conversationID = id
            return try Panel.turn(1, extras: extras)
        }
        let agents = turns.map { Panel.agent([$0]) }
        let codex = ChangesPanelModel.Agent(
            conversation: ConversationKey(provider: .codex, conversationID: "x", isFallback: false),
            turns: []
        )

        // The first ended with every turn viewed: still named, still #1.
        let named = ChangesPanelModel.conversations(Panel.input(agents + [codex], lines: [Panel.line(through: turns[0]).line]))

        #expect(named.map(\.conversation) == agents.map(\.conversation) + [codex.conversation])
        #expect(named.map(\.ordinal) == [1, 2, 3, nil], "Claude #1 to #3, and Codex by its kind")
        #expect(named.map(\.unviewedCount) == [0, 1, 1, 0])

        let alone = ChangesPanelModel.conversations(Panel.input([agents[1]]))
        #expect(alone.map(\.ordinal) == [nil], "one conversation: its kind names it")
    }

    /// One turn of conversation `id`, recorded with `title`.
    private static func titled(_ id: String, _ title: String?, number: Int = 1) throws -> TurnSummary {
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = id
        extras.conversationTitle = title
        return try Panel.turn(number, extras: extras)
    }

    private static func names(_ choices: [ConversationChoice]) -> [String] {
        choices.map { ConversationText.name($0, locale: english) }
    }

    @Test func choices_titledConversation_namesByTitle() throws {
        let agents = try [Self.titled("a", "Review the fork"), Self.titled("b", "Fix tests")].map { Panel.agent([$0]) }

        let named = ChangesPanelModel.conversations(Panel.input(agents))

        #expect(named.first?.title == "Review the fork")
        #expect(named.first?.ordinal == nil, "a title of its own needs no number")
        #expect(Self.names(named) == ["Review the fork", "Fix tests"])
    }

    /// A conversation's name carries its number only where its title, or
    /// its kind, does not tell it apart; the cards and file tags tell the
    /// rest apart by their identity colors.
    @Test func choices_ordinal_numbersOnlyWhereTheNameNeedsIt() throws {
        let agents = try [Self.titled("a", "Review the fork"), Self.titled("b", "Fix tests"), Self.titled("c", nil)]
            .map { Panel.agent([$0]) }
        let codex = ChangesPanelModel.Agent(
            conversation: ConversationKey(provider: .codex, conversationID: "x", isFallback: false),
            turns: []
        )

        let named = ChangesPanelModel.conversations(Panel.input(agents + [codex]))

        #expect(named.map(\.ordinal) == [nil, nil, 3, nil], "a title of its own needs no number in its name")
    }

    /// A conversation whose tab the person named is still called by that
    /// name once the tab is gone, over the title its agent gave it.
    @Test func choices_rememberedTabName_namesAnEndedConversation() throws {
        let agents = try [Self.titled("a", "Review the fork"), Self.titled("b", "Fix tests")].map { Panel.agent([$0]) }
        var input = Panel.input(agents)
        let named = agents[0].conversation
        input.tabName = { $0 == named ? "Payments" : nil }

        #expect(Self.names(ChangesPanelModel.conversations(input)) == ["Payments", "Fix tests"])
    }

    @Test func choices_sameTitle_appendsOrdinal() throws {
        let agents = try [Self.titled("a", "Fix tests"), Self.titled("b", "Fix tests")].map { Panel.agent([$0]) }

        let named = ChangesPanelModel.conversations(Panel.input(agents))

        #expect(named.map(\.ordinal) == [1, 2])
        #expect(Self.names(named) == ["Fix tests #1", "Fix tests #2"])
        #expect(named.map { ConversationText.name($0, locale: Self.japanese) } == ["Fix tests #1", "Fix tests #2"])
    }

    @Test func choices_untitledConversation_keepsOrdinal() throws {
        let agents = try [Self.titled("a", "Review the fork"), Self.titled("b", nil)].map { Panel.agent([$0]) }

        let named = ChangesPanelModel.conversations(Panel.input(agents))

        #expect(named.map(\.title) == ["Review the fork", nil])
        #expect(Self.names(named) == ["Review the fork", "Claude #2"])
    }

    /// The newest turn's title names the conversation: a rename after its
    /// first turns renames every one of them.
    @Test func choices_latestTurnTitle_namesWholeConversation() throws {
        let turns = try [Self.titled("a", "old", number: 1), Self.titled("a", "new", number: 2)]
        let other = try Self.titled("b", "Fix tests")

        let named = ChangesPanelModel.conversations(Panel.input([Panel.agent(turns), Panel.agent([other])]))

        #expect(named.first?.title == "new")
    }

    /// What the pane's agent calls its conversation now wins over what a
    /// turn recorded, which may be a title from before a rename.
    @Test func choices_liveTitle_winsOverRecordedTitle() throws {
        let agents = try [Self.titled("a", "Recorded"), Self.titled("b", nil)].map { Panel.agent([$0]) }
        var input = Panel.input(agents)
        let live = ConversationChoice.LiveTab(title: "claude", isInSession: true, providerTitle: "Renamed")
        input.liveTab = { $0 == agents[0].conversation ? live : nil }

        #expect(ChangesPanelModel.conversations(input).first?.title == "Renamed")
    }

    /// A conversation recorded with no title is named after the first
    /// thing it was asked.
    @Test func choices_noTitle_namesByFirstPrompt() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = "a"
        extras.promptHead = "Add the store tests"
        let first = try Panel.turn(1, extras: extras)
        extras.promptHead = "Now the docs"
        let second = try Panel.turn(2, extras: extras)
        let other = try Self.titled("b", nil)

        let named = ChangesPanelModel.conversations(Panel.input([Panel.agent([first, second]), Panel.agent([other])]))

        #expect(Self.names(named) == ["Add the store tests", "Claude #2"])
    }

    /// VoiceOver says the kind before a title, which alone does not say
    /// which agent it is.
    @Test func spokenName_saysTheKindBeforeTheTitle() throws {
        let agents = try [Self.titled("a", "Review the fork"), Self.titled("b", nil)].map { Panel.agent([$0]) }

        let named = ChangesPanelModel.conversations(Panel.input(agents))

        #expect(named.map { ConversationText.spokenName($0, locale: Self.english) } == ["Claude, Review the fork", "Claude #2"])
        #expect(named.map { ConversationText.spokenName($0, locale: Self.japanese) } == ["Claude、Review the fork", "Claude #2"])
    }

    // MARK: - Restore

    private static func recorded(_ number: Int, phase: String = "finished", changes: String = changed) throws -> TurnSummary {
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("b", number), root: "/repo")
        return try Panel.turn(number, phase: phase, changes: changes, extras: extras)
    }

    @Test func endedTurnsWithARecordedStart_offerARestore() throws {
        let turns = try [
            Self.recorded(4),
            Self.recorded(5),
            Self.recorded(6, changes: #"{"kind":"unchanged"}"#),
            Panel.turn(7),
            Self.recorded(8, phase: "started")
        ]
        let viewed = Panel.line(through: turns[0]).line

        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent(turns)], lines: [viewed])))

        // No start recorded, nothing changed, or still running: no restore.
        #expect(list.rows.map(\.offersRestore) == [true, true, false, false, false])
    }

    @Test func theTurnsARestoreTookBack_readAsRestored_andOfferNoRestore() throws {
        let turns = try [Self.recorded(4), Self.recorded(5), Self.recorded(6), Self.recorded(7)]
        var input = Panel.input([Panel.agent(turns)])
        // T7 began after the restore ran: new work, not restored.
        input.isRestored = { [5, 6].contains($0.displayNumber) }

        let list = try Panel.list(ChangesPanelModel.make(input))

        #expect(list.rows.map(\.status) == [.unviewed, .restored, .restored, .unviewed])
        // Nothing of a restored turn is left to read.
        #expect(list.unviewedCount == 2)
        #expect(ChangesPanelModel.unviewedCount(turns, line: nil, isRestored: input.isRestored) == 2)
        #expect(list.rows.map(\.offersRestore) == [true, false, false, true])
        // Its changes are gone: nothing to open, and no line to move there.
        #expect(list.rows.map(\.isSelectable) == [true, false, false, true])
        #expect(list.rows.map(\.action) == [.markViewedThrough, nil, nil, .markViewedThrough])
        #expect(ChangesPanelText.status(.restored, locale: Self.japanese) == "復元済み")
    }

    @Test func theGate_saysWhyAnEntryIsOff_onEveryRow_andUnderTheLastEntryOnly() throws {
        let turns = try [Self.recorded(4), Self.recorded(5), Self.recorded(6)]
        var input = Panel.input([Panel.agent(turns)], lines: [Panel.line(through: turns[0]).line])
        input.restoreBlocker = { _ in .agentWaiting }

        let list = try Panel.list(ChangesPanelModel.make(input))

        #expect(list.rows.map(\.restoreBlocker) == [.agentWaiting, .agentWaiting, .agentWaiting])
        #expect(list.rows.map(\.showsBlockerNote) == [false, false, true])
    }

    @Test func theGatesReason_isNotSaid_whileTheRestoreCanRun() throws {
        let turns = try [Self.recorded(4), Self.recorded(5)]
        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent(turns)])))

        #expect(list.rows.map(\.showsBlockerNote) == [false, false])
    }
}
