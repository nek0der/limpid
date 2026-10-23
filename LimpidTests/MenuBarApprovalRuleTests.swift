// MenuBarApprovalRuleTests.swift
// Limpid — which approval requests the menu bar extra offers to allow or deny, and which it only opens.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Limpid

struct MenuBarApprovalRuleTests {
    private static func offer(
        _ command: String?,
        isQuestion: Bool = false,
        supportsNativeAnswer: Bool = true,
        state: ApprovalRequestState = .held
    ) -> MenuBarApprovalRule.Offer {
        MenuBarApprovalRule.offer(isQuestion: isQuestion, supportsNativeAnswer: supportsNativeAnswer, command: command, state: state)
    }

    @Test func offer_shortCommand_allowsOrDenies() {
        #expect(Self.offer("make test") == .allowOrDeny)
    }

    @Test func offer_sixtyCharacters_allowsOrDenies_sixtyOne_doesNot() {
        let sixty = String(repeating: "a", count: 60)
        #expect(Self.offer(sixty) == .allowOrDeny)
        #expect(Self.offer(sixty + "a") == .tooLong)
    }

    @Test func offer_countsCharactersNotBytes() {
        let sixty = String(repeating: "あ", count: 60)
        #expect(Self.offer(sixty) == .allowOrDeny)
    }

    @Test(arguments: [
        "echo a\necho b",
        "echo a\r\necho b",
        "echo a\recho b",
        "echo a\u{2028}echo b",
        "echo a\u{85}echo b",
    ])
    func offer_commandOnSeveralLines_isTooLong(_ command: String) {
        #expect(Self.offer(command) == .tooLong)
    }

    /// Short, so the note must not call it long: what keeps it off the
    /// menu is a character that would not show as it runs.
    @Test(arguments: [
        "echo \u{202E}txt.exe",
        "echo \u{2066}a\u{2069}",
        "ec\u{200B}ho a",
        "echo\ta",
        "echo \u{1B}[2J",
        "echo \u{3164}",
        "e\u{034F}cho a",
        "echo a\u{FE0F}",
        "echo \u{E000}",
    ])
    func offer_shortCommandWithHiddenCharacters_isNotShownWhole(_ command: String) {
        #expect(Self.offer(command) == .notShownWhole)
    }

    /// Edit, a subagent, an MCP tool: the summary is a description, not
    /// what runs, so the menu never allows it.
    @Test func offer_toolThatRunsNoCommand_isAnsweredInLimpid() {
        #expect(Self.offer(nil) == .notACommand)
        // An empty command has no characters to hide; it runs nothing the
        // menu could show.
        #expect(Self.offer("") == .notACommand)
    }

    @Test func offer_highImpactCommand_isAnsweredInLimpid() {
        #expect(Self.offer("rm -rf build") == .highImpact)
        #expect(Self.offer("sudo make install") == .highImpact)
    }

    @Test func offer_questions_followWhoAnswersThem() {
        #expect(Self.offer(nil, isQuestion: true) == .answerInLimpid)
        #expect(Self.offer(nil, isQuestion: true, supportsNativeAnswer: false) == .openPane)
    }

    @Test func offer_handedOrTimedOut_isAnsweredInTheTerminal() {
        let now = SuspendingClock().now
        #expect(Self.offer("make test", state: .handedToTerminal(since: now)) == .handedToTerminal)
        #expect(Self.offer(nil, isQuestion: true, state: .handedToTerminal(since: now)) == .handedToTerminal)
        #expect(Self.offer("make test", state: .timedOut) == .timedOut)
    }

    @Test func offer_sendingOrAnswered_saysSo() {
        #expect(Self.offer("make test", state: .sending(.allowOnce, since: SuspendingClock().now)) == .sending)
        #expect(Self.offer("make test", state: .answered(.allowOnce)) == .answered)
        #expect(Self.offer(nil, isQuestion: true, state: .answered(.answer([:]))) == .answered)
    }

    @Test func offer_requestTakingNoDecision_onlyOpens() {
        #expect(Self.offer("make test", state: .withdrawn) == .openPane)
        #expect(Self.offer("make test", state: .unknownResult) == .openPane)
    }

    @Test func offer_failedSend_offersTheDecisionAgain() {
        #expect(Self.offer("make test", state: .sendFailed(.allowOnce, error: "x")) == .allowOrDeny)
    }
}
