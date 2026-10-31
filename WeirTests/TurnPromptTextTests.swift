// TurnPromptTextTests.swift
// Weir — a prompt the agent's harness wrote is worded by its kind, never quoted.

import Foundation
import Testing
@testable import Weir

@Suite("Turn prompt text")
struct TurnPromptTextTests {
    private typealias Fixture = TurnSummaryFixture
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let notification = "<task-notification> <task-id>bmtysm2i6</task-id>"

    private static func turn(head: String?, kind: TurnPromptKind?) throws -> TurnSummary {
        try Fixture.turn("A", number: 7, extras: .init(promptHead: head, promptKind: kind))
    }

    @Test func thePersonsWords_areShownTrimmed_andNothingWhenNoneWereKept() {
        #expect(TurnPromptText.instruction(TurnPrompt(head: "  add tests "), locale: Self.english) == "add tests")
        #expect(TurnPromptText.instruction(TurnPrompt(head: " "), locale: Self.english) == nil)
        #expect(TurnPromptText.instruction(TurnPrompt(head: nil), locale: Self.english) == nil)
    }

    @Test(arguments: [
        (TurnPromptKind.backgroundTask, "Background work done", "バックグラウンド作業の完了"),
        (.subagentMessage, "Message from a subagent", "サブエージェントからのメッセージ"),
        (.injected, "Automatic message to the agent", "エージェントへの自動メッセージ"),
    ])
    func aPromptTheHarnessWrote_isWordedByItsKind(kind: TurnPromptKind, english: String, japanese: String) {
        let prompt = TurnPrompt(kind: kind, head: Self.notification)
        #expect(TurnPromptText.instruction(prompt, locale: Self.english) == english)
        #expect(TurnPromptText.instruction(prompt, locale: Self.japanese) == japanese)
        // Without a head too: the kind alone says what the turn was.
        #expect(TurnPromptText.instruction(TurnPrompt(kind: kind, head: nil), locale: Self.english) == english)
    }

    /// A turn Codex began for the person's goal quotes the goal, which is
    /// their words, after the command they set it with, in either language;
    /// with no words kept, the command alone says it.
    @Test func aGoalsTurn_quotesTheGoal_afterTheCommand() {
        let prompt = TurnPrompt(kind: .goal, head: "  Ship the release ")
        #expect(TurnPromptText.instruction(prompt, locale: Self.english) == "/goal Ship the release")
        #expect(TurnPromptText.instruction(prompt, locale: Self.japanese) == "/goal Ship the release")
        #expect(TurnPromptText.instruction(TurnPrompt(kind: .goal, head: nil), locale: Self.english) == "/goal")
        #expect(TurnPromptText.instruction(TurnPrompt(kind: .goal, head: " "), locale: Self.japanese) == "/goal")
    }

    /// Cut for a menu line as the person's words are, the command kept whole.
    @Test func aGoalsTurn_isCutByItsGoal_forAMenuLine() {
        let prompt = TurnPrompt(kind: .goal, head: "Ship the release notes")
        #expect(TurnPromptText.shortInstruction(prompt, characters: 8, locale: Self.english) == "/goal Ship the…")
        #expect(TurnPromptText.shortInstruction(prompt, characters: 40, locale: Self.english) == "/goal Ship the release notes")
        #expect(
            TurnPromptText.shortInstruction(TurnPrompt(head: "Ship the release notes"), characters: 8, locale: Self.english)
                == "Ship the…"
        )
    }

    @Test func theChangesPanel_showsTheKind_inTheRowsTooltip() throws {
        let turn = try Self.turn(head: Self.notification, kind: .backgroundTask)
        #expect(ChangesPanelText.turnDetails(turn, showsChanges: false, locale: Self.english) == ["Background work done"])
        #expect(ChangesPanelText.turnDetails(turn, showsChanges: false, locale: Self.japanese) == ["バックグラウンド作業の完了"])
    }

    /// The person's words the hook kept as the head, after a reminder it
    /// judged as theirs, read as the person's everywhere.
    @Test func thePersonsWordsAfterALongReminder_areTheInstruction() throws {
        let judged = try Self.turn(head: "add the tests", kind: .text)
        #expect(TurnPromptText.instruction(judged.prompt, locale: Self.japanese) == "add the tests")
        #expect(ChangesPanelText.turnDetails(judged, showsChanges: false, locale: Self.english) == ["add the tests"])
    }

    @Test func theReviewScope_namesTheTurnByItsKind_withoutCuttingIt() throws {
        let turn = try Fixture.turn(
            "A",
            changes: Fixture.changedFiles,
            number: 7,
            endTree: SnapshotTree(tree: Fixture.tree("e", 7), root: "/repo"),
            extras: .init(
                beginTree: SnapshotTree(tree: Fixture.tree("b", 7), root: "/repo"),
                promptHead: #"<agent-message from="ade08c9a"> [Subagent hand-back]"#,
                promptKind: .subagentMessage
            )
        )
        let options = ReviewScopeCatalog.options(turns: [turn], isViewed: { _ in false }, branchBase: nil, hasChangesOutsideTurns: false)
        // After the unviewed turns, the turn itself.
        let option = try #require(options.dropFirst().first)
        let range = try #require(ReviewTurnRange(turns: [turn]))
        #expect(option == .turn(range, prompt: turn.prompt))
        // In full: only the person's words are cut to the scope's length.
        #expect(ReviewTabText.option(option, locale: Self.english) == "T7 · Message from a subagent")
        #expect(ReviewTabText.option(option, locale: Self.japanese) == "T7 · サブエージェントからのメッセージ")
    }
}
