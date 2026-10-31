// AttentionAnnouncementTests.swift
// Weir — what VoiceOver announces as an item arrives: its state named as its row names it, then its tab.

import Foundation
import Testing
@testable import Weir

struct AttentionAnnouncementTests {
    @Test(arguments: [
        (AttentionItemKind.prompt(PromptWait(detail: "Write: /a.txt")), "Needs approval", "承認待ち"),
        (.prompt(PromptWait(detail: "Which color?", kind: .question, tool: nil)), "Needs answer", "回答待ち"),
        (.prompt(PromptWait(detail: "Which color?")), "Needs response", "応答待ち"),
        (.stop(.processExited), "Stopped", "停止"),
        (.unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown)), "Unread", "未読")
    ])
    func anItemsAnnouncement_namesItAsItsRowDoes(kind: AttentionItemKind, english: String, japanese: String) {
        #expect(AttentionEffectPerformer.announcement(of: kind, tabTitle: nil, locale: Locale(identifier: "en")) == english)
        #expect(AttentionEffectPerformer.announcement(of: kind, tabTitle: nil, locale: Locale(identifier: "ja")) == japanese)
    }

    @Test func aRequestsAnnouncement_namesIt_thenItsTab() {
        let approval = AttentionEffectPerformer.announcement(
            of: .approval(ApprovalFact.test()),
            tabTitle: "Fix tests",
            locale: Locale(identifier: "en")
        )
        #expect(approval == "Needs approval, Fix tests", "a list, not the tooltip’s ·, which VoiceOver reads")
        let question = AttentionEffectPerformer.announcement(
            of: .question(ApprovalFact.test(isQuestion: true)),
            tabTitle: "Fix tests",
            locale: Locale(identifier: "ja")
        )
        #expect(question == "回答待ち、Fix tests")
    }
}
