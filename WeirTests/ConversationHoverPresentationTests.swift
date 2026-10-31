// ConversationHoverPresentationTests.swift
// Weir — which conversation a window highlights, and when a tab's hover starts counting.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("ConversationHoverPresentation")
struct ConversationHoverPresentationTests {
    private let clock = ManualTimer()
    private let first = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
    private let second = ConversationKey(provider: .codex, conversationID: "c2", isFallback: false)
    private let cardA = ConversationHoverPresentation.Surface.card(TurnID("a"))
    private let cardB = ConversationHoverPresentation.Surface.card(TurnID("b"))
    private let tab = ConversationHoverPresentation.Surface.tab(UUID())

    private func makePresentation() -> ConversationHoverPresentation {
        ConversationHoverPresentation(timer: clock.timer)
    }

    @Test func leave_otherKey_keepsHovered() {
        let presentation = makePresentation()
        presentation.enter([first], from: cardA)
        presentation.leave([second], from: cardB)
        #expect(presentation.hovered == .init(conversations: [first], source: .card))
    }

    @Test func enterFromCard_isImmediate() {
        let presentation = makePresentation()
        presentation.enter([first], from: cardA)
        #expect(presentation.hovered == .init(conversations: [first], source: .card))
    }

    @Test func enterFromTab_waitsTheTabDelay() {
        let presentation = makePresentation()
        presentation.enter([first], from: tab)
        clock.advance(by: .milliseconds(149))
        #expect(presentation.hovered == nil)
        clock.advance(by: .milliseconds(1))
        #expect(presentation.hovered == .init(conversations: [first], source: .tab))
    }

    @Test func enterFromTab_leaveBeforeDelay_cancels() {
        let presentation = makePresentation()
        presentation.enter([first], from: tab)
        clock.advance(by: .milliseconds(100))
        presentation.leave([first], from: tab)
        clock.advance(by: .milliseconds(100))
        #expect(presentation.hovered == nil)
    }

    /// Card A to card B of one conversation, B's enter delivered before
    /// A's leave: B's hover stays, and with it the tab's outline.
    @Test func leave_sameConversationOtherCard_keepsHovered() {
        let presentation = makePresentation()
        presentation.enter([first], from: cardA)
        presentation.enter([first], from: cardB)
        presentation.leave([first], from: cardA)
        #expect(presentation.hovered == .init(conversations: [first], source: .card))
        presentation.leave([first], from: cardB)
        #expect(presentation.hovered == nil)
    }

    /// Another tab's late leave does not cancel the tab hover waiting out
    /// its delay.
    @Test func enterFromTab_otherTabsLeave_keepsPending() {
        let presentation = makePresentation()
        let other = ConversationHoverPresentation.Surface.tab(UUID())
        presentation.enter([first], from: tab)
        presentation.leave([first], from: other)
        clock.advance(by: ConversationHoverPresentation.tabDelay)
        #expect(presentation.hovered == .init(conversations: [first], source: .tab))
    }

    /// A section's heading marks its tab at once, as a card does, and its
    /// leave clears only the hover it set.
    @Test func enterFromHeading_isACardHover() {
        let presentation = makePresentation()
        let heading = ConversationHoverPresentation.Surface.heading(first)
        presentation.enter([first], from: heading)
        #expect(presentation.hovered == .init(conversations: [first], source: .card))

        presentation.enter([first], from: cardA)
        presentation.leave([first], from: heading)
        #expect(presentation.hovered == .init(conversations: [first], source: .card), "the card's hover stays")
        presentation.leave([first], from: cardA)
        #expect(presentation.hovered == nil)
    }
}
