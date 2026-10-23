// VoiceOverWordingTests.swift
// Limpid — what VoiceOver reads says counts, places, turns, and lines in words, not in the symbols drawn for the eye.

import Foundation
import Testing
@testable import Limpid

/// The drawn forms keep their symbols ("4/4", "T7", "·", "→", "@@"), which
/// VoiceOver reads as a date, letter by letter, or as the symbol's name.
/// Each spoken form here is the one the labels hand VoiceOver instead.
struct VoiceOverWordingTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test func tooltipFacts_andPlaces_areReadAsTheLocalesList() {
        #expect(AgentStatusText.spoken("Claude · Running", locale: Self.english) == "Claude, Running")
        #expect(AgentStatusText.spoken("Claude · 実行中", locale: Self.japanese) == "Claude、実行中")
        #expect(AgentStatusText.spokenPlace("alpha / feat/login", locale: Self.japanese) == "alpha、feat/login")
        #expect(AgentStatusText.spokenPlace("alpha", locale: Self.english) == "alpha")
    }

    @Test func aTurn_isReadAsTheWord_notItsLetter() {
        #expect(ReceiptText.spokenTurn(7, locale: Self.english) == "Turn 7")
        #expect(ReceiptText.spokenTurn(7, locale: Self.japanese) == "ターン 7")
        #expect(ReceiptText.spokenTurns(6...7, locale: Self.english) == "Turns 6 to 7")
        #expect(ReceiptText.spokenTurns(6...7, locale: Self.japanese) == "ターン 6 から 7")
        #expect(ReceiptText.spokenTurns(3...3, locale: Self.japanese) == "ターン 3")
    }

    @Test func pullRequestChecks_sayTheirCounts_inWords() {
        let failed = PRChecks(conclusion: .failure, counts: .init(passed: 3, total: 4))
        #expect(PRChecksText.make(failed, forge: .gitHub, locale: Self.english) == "Checks failed (3/4 passed)", "the card keeps its form")
        #expect(PRChecksText.spoken(failed, forge: .gitHub, locale: Self.english) == "Checks failed, 3 of 4 passed")
        #expect(PRChecksText.spoken(failed, forge: .gitHub, locale: Self.japanese) == "チェック失敗、4 件中 3 件成功")
        let passed = PRChecks(conclusion: .success, counts: .init(passed: 4, total: 4))
        #expect(PRChecksText.spoken(passed, forge: .gitHub, locale: Self.japanese) == "チェック成功、4 件中 4 件")
        let running = PRChecks(conclusion: .pending, counts: nil)
        #expect(PRChecksText.spoken(running, forge: .gitLab, locale: Self.english) == PRChecksText.make(
            running,
            forge: .gitLab,
            locale: Self.english
        ))
    }

    @Test func theTimeLeft_isReadAsMinutesAndSeconds_notAClock() {
        let english = ApprovalCardModel.spokenTimeLeftText(for: .seconds(522), locale: Self.english)
        #expect(english.contains("8 minutes") && english.contains("42 seconds") && english.hasSuffix("left"), "\(english)")
        let japanese = ApprovalCardModel.spokenTimeLeftText(for: .seconds(522), locale: Self.japanese)
        #expect(japanese.hasPrefix("残り") && japanese.contains("8分") && japanese.contains("42秒"), "\(japanese)")
        #expect(!japanese.contains(":"))
        #expect(ApprovalCardModel.spokenTimeLeftText(for: .zero, locale: Self.english) == "0 seconds left", "nothing left still says so")
    }

    @Test func aCodeLine_saysWhereItSits_andWhetherItWasAddedOrRemoved() {
        let added = ReviewLine(id: 1, kind: .added, text: "new value", oldLine: nil, newLine: 11)
        let removed = ReviewLine(id: 2, kind: .removed, text: "old value", oldLine: 10, newLine: nil)
        let context = ReviewLine(id: 3, kind: .context, text: "shared", oldLine: 12, newLine: 13)
        #expect(added.spokenPosition(locale: Self.english) == "Added, new line 11")
        #expect(removed.spokenPosition(locale: Self.japanese) == "削除、変更前 10 行目")
        #expect(context.spokenPosition(locale: Self.japanese) == "変更前 12 行目、変更後 13 行目")
        #expect(
            ReviewComment.spokenPosition(oldStart: nil, oldEnd: nil, newStart: 12, newEnd: 18, locale: Self.english) == "Lines 12 to 18"
        )
        #expect(
            ReviewComment.spokenPosition(oldStart: 10, oldEnd: 10, newStart: 12, newEnd: 12, locale: Self.english)
                == "Old line 10, new line 12"
        )
    }

    @Test func aHunksComment_isNamedByItsLine_notItsHeader() {
        #expect(ReviewHunkCommentText
            .commentLabel(header: "@@ -3,3 +5,4 @@ func foo()", locale: Self.english) == "Comment on the Hunk at Line 5")
        #expect(ReviewHunkCommentText.commentLabel(header: "@@ -3 +5 @@", locale: Self.japanese) == "5 行目からのハンクにコメント")
        #expect(ReviewHunkCommentText.commentLabel(header: "", locale: Self.english) == "Comment")
        #expect(
            ReviewHunkCommentText.commentLabel(header: "@@ -1,3 +0,0 @@", locale: Self.english) == "Comment on the Hunk at Line 1",
            "a deleted file's hunk is named by its old side"
        )
    }

    @Test func theFileListsProgress_isReadWithoutItsSlash() {
        let progress = ReviewReadingProgress(fileIDs: ["a", "b", "c"], viewed: ["a"])
        #expect(ReviewStackText.spokenProgress(progress, locale: Self.english) == "1 of 3 viewed")
        #expect(ReviewStackText.spokenProgress(progress, locale: Self.japanese) == "3 件中 1 件を確認済み")
    }

    @Test func anAllProjectsCardsPlace_isReadAsAList() {
        #expect(AllProjectsText.spokenPlace(project: "limpid", branch: "feat/pricing", locale: Self.japanese) == "limpid、feat/pricing")
        #expect(AllProjectsText.spokenPlace(project: "limpid", branch: nil, locale: Self.english) == "limpid")
    }
}
