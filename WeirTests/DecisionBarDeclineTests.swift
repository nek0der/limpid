// DecisionBarDeclineTests.swift
// Weir — the decision bar says a wait declined at the agent's own prompt was declined, not answered.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// Claude sends no hook when the person declines its question or permission
/// prompt with Esc. The bar's line after the wait leaves says what happened,
/// read from the run the projection returns rather than from timing.
@MainActor
struct DecisionBarDeclineTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let pane = UUID()

    private static func items(_ kinds: [AttentionItemKind]) -> [AttentionItem] {
        AttentionItem.testList(kinds, pane: pane, provider: .claude, filesRequestsByKey: true)
    }

    private static func model(_ input: DecisionBarContent.Input, locale: Locale = english) -> DecisionBarModel {
        DecisionBarModel(content: DecisionBarContent.make(input), locale: locale)
    }

    /// Esc at Claude's own prompt declines the question rather than
    /// answering it, and stops the turn, so the line says that.
    @Test func rightAfterADeclineInTheTerminal_theBarSaysItWasDeclined_notAnswered() {
        let none = Self.model(.init(done: .init(result: .declinedInTerminal, next: nil)))
        #expect(none.text == "Declined in the terminal. Nothing needs attention.")
        let japanese = Self.model(.init(done: .init(result: .declinedInTerminal, next: nil)), locale: Self.japanese)
        #expect(japanese.text == "ターミナルでキャンセルしました。要対応はありません。")
        let answered = Self.model(.init(done: .init(result: .answeredInTerminal, next: nil)), locale: Self.japanese)
        #expect(answered.text == "ターミナルで回答しました。要対応はありません。")
        #expect(Self.model(.init(done: .init(result: .declinedInTerminal, next: nil))).undo == nil)
    }

    @Test func aWaitThatLeftDeclined_setsTheDeclinedLine_andOneAnswered_theAnsweredLine() {
        let prompt = Self.items([.prompt(PromptWait(detail: nil))])
        let handed = Self.items([.approval(ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now)))])
        let held = Self.items([.approval(ApprovalFact.test())])
        for shown in [prompt.first, handed.first] {
            let declined = DecisionBarModel.doneUpdate(lastShown: shown, items: [], hasMovedOnSinceShown: false, isDeclined: true)
            #expect(declined == .set(.declinedInTerminal))
            let answered = DecisionBarModel.doneUpdate(lastShown: shown, items: [], hasMovedOnSinceShown: false, isDeclined: false)
            #expect(answered == .set(.answeredInTerminal))
        }
        // A request on the card, or a pane moved on, says nothing either way.
        #expect(DecisionBarModel.doneUpdate(lastShown: held.first, items: [], hasMovedOnSinceShown: false, isDeclined: true) == .keep)
        #expect(DecisionBarModel.doneUpdate(lastShown: prompt.first, items: [], hasMovedOnSinceShown: true, isDeclined: true) == .keep)
    }

    /// Declined is read from the run, never from timing: the badge the
    /// projection read from the transcript, else a finished run whose turn
    /// ended interrupted once the record was written.
    @Test func aDecline_isTheProjectionsWord_orAnInterruptedTurnTheRunRestsAfter() throws {
        var declinedBadge = AgentBadge(state: .finished, updatedAt: Date())
        declinedBadge.stopReason = AgentBadge.waitDeclinedReason
        #expect(DecisionBarModel.isDeclined(runtime: AgentRuntimePresentation.test(badge: declinedBadge), turn: nil))

        let finished = AgentRuntimePresentation.test(badge: AgentBadge(state: .finished, updatedAt: Date()))
        let interrupted = try TurnSummaryFixture.turn("T1", phase: "interrupted")
        let completed = try TurnSummaryFixture.turn("T1", phase: "finished")
        #expect(DecisionBarModel.isDeclined(runtime: finished, turn: interrupted))
        #expect(!DecisionBarModel.isDeclined(runtime: finished, turn: completed))
        #expect(!DecisionBarModel.isDeclined(runtime: finished, turn: nil))
        // An answer moves the run on to work.
        #expect(!DecisionBarModel.isDeclined(runtime: AgentRuntimePresentation.test(), turn: interrupted))
        #expect(!DecisionBarModel.isDeclined(runtime: nil, turn: interrupted))
    }
}
