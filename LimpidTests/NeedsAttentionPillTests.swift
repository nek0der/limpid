// NeedsAttentionPillTests.swift
// Limpid — the title bar's attention count: amber only when something blocks, and what its tooltip says.

import Foundation
import Testing
@testable import Limpid

struct NeedsAttentionPillTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test(arguments: [
        (AttentionCounts(approvals: 1), NeedsAttentionPillModel.Style.blocking),
        (AttentionCounts(questions: 1), .blocking),
        (AttentionCounts(prompts: 1), .blocking),
        (AttentionCounts(stops: 1), .blocking),
        (AttentionCounts(approvals: 1, unread: 4), .blocking),
        (AttentionCounts(unread: 2), .unreadOnly),
        (AttentionCounts(), .empty)
    ])
    func amber_meansSomethingBlocks_andUnreadAlone_isABlueOutline(_ counts: AttentionCounts, _ style: NeedsAttentionPillModel.Style) {
        #expect(NeedsAttentionPillModel(counts).style == style)
    }

    @Test func theCount_staysAtZero_ratherThanDisappearing() {
        let empty = NeedsAttentionPillModel(AttentionCounts())
        #expect(empty.count == 0)
        #expect(empty.label.resolved(in: Self.english) == "Needs Attention · 0")
        #expect(empty.label.resolved(in: Self.japanese) == "要対応 0")
    }

    @Test func theTooltip_namesTheKeys_andTheKindsThatHaveItems() {
        let pill = NeedsAttentionPillModel(AttentionCounts(approvals: 1, prompts: 1, stops: 1, unread: 2))

        #expect(pill.tooltip(listShortcut: "⌃⌘J", nextShortcut: "⌘J", locale: Self.english)
            == "Needs Attention list (⌃⌘J; Next Action: ⌘J) · 1 Approval · 1 Response · 1 Stopped · 2 Unread")
        #expect(pill.tooltip(listShortcut: "⌃⌘J", nextShortcut: "⌘J", locale: Self.japanese)
            == "要対応の一覧（⌃⌘J。次の対応は ⌘J） · 承認 1 · 応答 1 · 停止 1 · 未読 2")
    }

    @Test func anUnboundKey_isLeftOutOfTheTooltip() {
        let pill = NeedsAttentionPillModel(AttentionCounts())

        #expect(pill.tooltip(listShortcut: nil, nextShortcut: "⌘J", locale: Self.english) == "Needs Attention list (Next Action: ⌘J)")
        #expect(pill.tooltip(listShortcut: "⌃⌘J", nextShortcut: nil, locale: Self.english) == "Needs Attention list (⌃⌘J)")
        #expect(pill.tooltip(listShortcut: nil, nextShortcut: nil, locale: Self.english) == "Needs Attention list")
    }
}
