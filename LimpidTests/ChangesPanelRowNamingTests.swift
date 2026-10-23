// ChangesPanelRowNamingTests.swift
// Limpid — the changes panel's conversation names and its restore entries on timeline rows.

import Foundation
import Testing
@testable import Limpid

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
