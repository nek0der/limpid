// ConversationHoverRuleTests.swift
// Weir — which tab and which turn cards a hovered conversation marks.

import Foundation
import Testing
@testable import Weir

@Suite("ConversationHoverRule")
struct ConversationHoverRuleTests {
    private let first = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
    private let second = ConversationKey(provider: .codex, conversationID: "c2", isFallback: false)

    @Test func cardEmphasis_noHover_isNone() {
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: nil, hasIdentity: true) == .none)
    }

    @Test func cardEmphasis_tabHoverSameConversation_isLit() {
        let hover = ConversationHover(conversations: [first], source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: hover, hasIdentity: true) == .lit)
    }

    @Test func cardEmphasis_tabHoverOtherConversation_isDimmed() {
        let hover = ConversationHover(conversations: [second], source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: hover, hasIdentity: true) == .dimmed)
    }

    @Test func cardEmphasis_cardHover_neverDims() {
        let other = ConversationHover(conversations: [second], source: .card)
        let same = ConversationHover(conversations: [first], source: .card)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: other, hasIdentity: true) == .none)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: same, hasIdentity: true) == .none)
    }

    /// The hovered tab's own card with no color has none to be outlined in.
    @Test func cardEmphasis_noIdentity_isNone() {
        let same = ConversationHover(conversations: [first], source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: same, hasIdentity: false) == .none)
    }

    @Test func cardEmphasis_noConversation_isNone() {
        let other = ConversationHover(conversations: [second], source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: nil, hover: other, hasIdentity: false) == .none)
    }

    /// A card whose conversation gave its color back (it ended with every
    /// turn viewed) still steps back behind another conversation's tab.
    @Test func cardEmphasis_tabHoverOtherUncoloredConversation_isDimmed() {
        let other = ConversationHover(conversations: [second], source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: other, hasIdentity: false) == .dimmed)
    }

    /// A split tab answers for every conversation it runs: neither of its
    /// panes' cards steps back behind it.
    @Test func cardEmphasis_hoverOfATabRunningBoth_lightsTheCardsOfBoth() {
        let tab = ConversationHover(conversations: [first, second], source: .tab)
        let other = ConversationKey(provider: .claude, conversationID: "c3", isFallback: false)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: tab, hasIdentity: true) == .lit)
        #expect(ConversationHoverRule.cardEmphasis(of: second, hover: tab, hasIdentity: true) == .lit)
        #expect(ConversationHoverRule.cardEmphasis(of: other, hover: tab, hasIdentity: true) == .dimmed)
    }

    /// The selected tab's pane is framed in sight, so the tab says nothing more.
    @Test func tabOutline_selectedTab_isNone() {
        let card = ConversationHover(conversations: [first], source: .card)
        #expect(ConversationHoverRule.tabOutline(running: [first: 2], isSelected: true, hover: card) == nil)
        #expect(ConversationHoverRule.tabOutline(running: [first: 2], isSelected: false, hover: card) == 2)
    }

    @Test func framesPane_onlyUnderACardOfItsConversation() {
        let card = ConversationHover(conversations: [first], source: .card)
        let tab = ConversationHover(conversations: [first], source: .tab)
        #expect(ConversationHoverRule.framesPane(of: first, hover: card))
        #expect(!ConversationHoverRule.framesPane(of: second, hover: card))
        #expect(!ConversationHoverRule.framesPane(of: first, hover: tab))
        #expect(!ConversationHoverRule.framesPane(of: nil, hover: card))
    }

    @Test func tabOutline_cardHoverOfConversationTheTabRuns_isThatColor() {
        let same = ConversationHover(conversations: [first], source: .card)
        let ownTab = ConversationHover(conversations: [first], source: .tab)
        #expect(ConversationHoverRule.tabOutline(running: [first: 2], isSelected: false, hover: same) == 2)
        // Only a tab that runs the card's conversation, never for the
        // tab's own hover, and never without a color.
        #expect(ConversationHoverRule.tabOutline(running: [second: 1], isSelected: false, hover: same) == nil)
        #expect(ConversationHoverRule.tabOutline(running: [first: 2], isSelected: false, hover: ownTab) == nil)
        #expect(ConversationHoverRule.tabOutline(running: [:], isSelected: false, hover: same) == nil)
        #expect(ConversationHoverRule.tabOutline(running: [first: 2], isSelected: false, hover: nil) == nil)
    }

    /// A split tab whose title stands for one conversation is outlined for
    /// the card of the conversation in its second pane, in that one's color.
    @Test func tabOutline_splitTab_answersForItsSecondPaneInItsColor() {
        let secondPane = ConversationHover(conversations: [second], source: .card)
        #expect(ConversationHoverRule.tabOutline(running: [first: 0, second: 3], isSelected: false, hover: secondPane) == 3)
    }
}
