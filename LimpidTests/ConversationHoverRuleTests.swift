// ConversationHoverRuleTests.swift
// Limpid — which tab and which turn cards a hovered conversation marks.

import Foundation
import Testing
@testable import Limpid

@Suite("ConversationHoverRule")
struct ConversationHoverRuleTests {
    private let first = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
    private let second = ConversationKey(provider: .codex, conversationID: "c2", isFallback: false)

    @Test func cardEmphasis_noHover_isNone() {
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: nil, hasIdentity: true) == .none)
    }

    @Test func cardEmphasis_tabHoverSameConversation_isLit() {
        let hover = ConversationHover(conversation: first, source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: hover, hasIdentity: true) == .lit)
    }

    @Test func cardEmphasis_tabHoverOtherConversation_isDimmed() {
        let hover = ConversationHover(conversation: second, source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: hover, hasIdentity: true) == .dimmed)
    }

    @Test func cardEmphasis_cardHover_neverDims() {
        let other = ConversationHover(conversation: second, source: .card)
        let same = ConversationHover(conversation: first, source: .card)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: other, hasIdentity: true) == .none)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: same, hasIdentity: true) == .none)
    }

    /// The hovered tab's own card with no color has none to be outlined in.
    @Test func cardEmphasis_noIdentity_isNone() {
        let same = ConversationHover(conversation: first, source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: same, hasIdentity: false) == .none)
    }

    @Test func cardEmphasis_noConversation_isNone() {
        let other = ConversationHover(conversation: second, source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: nil, hover: other, hasIdentity: false) == .none)
    }

    /// A card whose conversation gave its color back (it ended with every
    /// turn viewed) still steps back behind another conversation's tab.
    @Test func cardEmphasis_tabHoverOtherUncoloredConversation_isDimmed() {
        let other = ConversationHover(conversation: second, source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: other, hasIdentity: false) == .dimmed)
    }

    @Test func tabOutline_cardHoverOfConversationTheTabRuns_isThatColor() {
        let same = ConversationHover(conversation: first, source: .card)
        let ownTab = ConversationHover(conversation: first, source: .tab)
        #expect(ConversationHoverRule.tabOutline(running: [first: 2], hover: same) == 2)
        // Only a tab that runs the card's conversation, never for the
        // tab's own hover, and never without a color.
        #expect(ConversationHoverRule.tabOutline(running: [second: 1], hover: same) == nil)
        #expect(ConversationHoverRule.tabOutline(running: [first: 2], hover: ownTab) == nil)
        #expect(ConversationHoverRule.tabOutline(running: [:], hover: same) == nil)
        #expect(ConversationHoverRule.tabOutline(running: [first: 2], hover: nil) == nil)
    }

    /// A split tab whose title stands for one conversation is outlined for
    /// the card of the conversation in its second pane, in that one's color.
    @Test func tabOutline_splitTab_answersForItsSecondPaneInItsColor() {
        let secondPane = ConversationHover(conversation: second, source: .card)
        #expect(ConversationHoverRule.tabOutline(running: [first: 0, second: 3], hover: secondPane) == 3)
    }
}
