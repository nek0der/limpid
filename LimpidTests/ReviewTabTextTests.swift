// ReviewTabTextTests.swift
// Limpid — the review tab's words: its name and title, the scope menu's entries, the band, and the file tags, in
// English and Japanese.

import Foundation
import Testing
@testable import Limpid

@Suite("Review tab text")
struct ReviewTabTextTests {
    private static let en = Locale(identifier: "en")
    private static let ja = Locale(identifier: "ja")

    /// Turn `number` of the fixture's conversation, with both snapshots and
    /// the prompt `prompt` begins with.
    private static func turn(_ number: Int, prompt: String? = nil) throws -> TurnSummary {
        try TurnSummaryFixture.turn(
            "T\(number)",
            changes: TurnSummaryFixture.changedFiles,
            number: number,
            endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", number), root: "/repo"),
            extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", number), root: "/repo"), promptHead: prompt)
        )
    }

    private static func context(_ turns: [TurnSummary]) -> ReviewTabModel.Context {
        ReviewTabModel.Context(turns: turns, isViewed: { _ in false }, branchBase: "main")
    }

    private static func open(_ request: ReviewTabRequest, _ context: ReviewTabModel.Context) -> ReviewTabState? {
        try? ReviewTabModel.open(request, context, root: "/repo", agentPaneID: UUID(), current: nil).get()
    }

    private static func claude(ordinal: Int) -> ConversationChoice {
        ConversationChoice(conversation: TurnSummaryFixture.conversation("claude"), ordinal: ordinal, unviewedCount: 1)
    }

    @Test func theWords_inEnglish() throws {
        let en = Locale(identifier: "en")
        let context = try Self.context([
            Self.turn(6, prompt: "Exactly eighteen c"),
            Self.turn(7, prompt: "Add tests for the timeline store please")
        ])
        let unviewed = try #require(Self.open(.unviewedTurns, context))
        let turn = try #require(Self.open(.latestTurn, context))
        let exact = try #require(Self.open(.turn(TurnID("T6")), context))

        #expect(ReviewTabText.tabName(unviewed.selection, locale: en) == "Unviewed Turns")
        #expect(ReviewTabText.title(unviewed.selection, locale: en) == "Review · Unviewed Turns")
        #expect(ReviewTabText.option(unviewed.selection, locale: en) == "Unviewed Turns (T6–T7)")
        #expect(ReviewTabText.option(turn.selection, locale: en) == "T7 · Add tests for the…")
        #expect(ReviewTabText.tabName(turn.selection, locale: en) == "T7 · Add tests for the…")
        #expect(ReviewTabText.title(turn.selection, locale: en) == "Review · T7 · Add tests for the…")
        #expect(ReviewTabText.option(exact.selection, locale: en) == "T6 · Exactly eighteen c", "18 characters fit")
        #expect(ReviewTabText.option(.unviewedTurns(.none), locale: en) == "Unviewed Turns (None)")
        #expect(ReviewTabText.title(.uncommitted(includesChangesOutsideTurns: true), locale: en) == "Review · Uncommitted Changes")
        #expect(ReviewTabText.option(.branch(base: "main"), locale: en) == "Changes from main")
        #expect(ReviewTabText.emptyScope(.incompleteTurn(7)) == .incompleteRecord)
        #expect(ReviewTabText.emptyScope(.incompleteTurn(7)).message(locale: en) == "Incomplete Record")
        #expect(ReviewTabText.emptyScope(.branch(base: "main")) == .noChangesInScope)
        #expect(ReviewTabText.band(.unviewedFiles(1), locale: en) == "1 unviewed file")
        #expect(try ReviewTabText.followingTurns([Self.turn(8), Self.turn(9)], locale: en) == "T8–T9 finished")
    }

    @Test func theWords_inJapanese() throws {
        let ja = Locale(identifier: "ja")
        let context = try Self.context([Self.turn(6), Self.turn(7, prompt: "タイムラインのストアのテストを追加してください")])
        let unviewed = try #require(Self.open(.unviewedTurns, context))
        let turn = try #require(Self.open(.latestTurn, context))

        #expect(ReviewTabText.tabName(unviewed.selection, locale: ja) == "未確認のターン")
        #expect(ReviewTabText.title(unviewed.selection, locale: ja) == "レビュー · 未確認のターン")
        #expect(ReviewTabText.option(unviewed.selection, locale: ja) == "未確認のターン（T6〜T7）")
        #expect(ReviewTabText.option(turn.selection, locale: ja) == "T7 · タイムラインのストアのテストを追加し…")
        #expect(ReviewTabText.option(.uncommitted(includesChangesOutsideTurns: true), locale: ja) == "未コミットの変更（ターン外を含む）")
        #expect(ReviewTabText.tabName(.uncommitted(includesChangesOutsideTurns: true), locale: ja) == "未コミットの変更")
        #expect(ReviewTabText.title(.uncommitted(includesChangesOutsideTurns: true), locale: ja) == "レビュー · 未コミットの変更")
        #expect(ReviewTabText.option(.branch(base: "main"), locale: ja) == "main との差分")
        #expect(try ReviewTabText.followingTurns([Self.turn(8)], locale: ja) == "T8 が終了しました")
    }

    @Test func theWords_inEnglishAndJapanese_eachNumberWithItsUnit() {
        #expect(ReviewTabText.worktreeHeading(locale: Self.en) == "All Conversations")
        #expect(ReviewTabText.worktreeHeading(locale: Self.ja) == "すべての会話")
        #expect(ReviewTabText.includesViewedTurns(0, locale: Self.en) == nil)
        #expect(ReviewTabText.includesViewedTurns(1, locale: Self.en) == "Includes 1 viewed turn")
        #expect(ReviewTabText.includesViewedTurns(2, locale: Self.en) == "Includes 2 viewed turns")
        #expect(ReviewTabText.includesViewedTurns(2, locale: Self.ja) == "範囲に確認済みのターン 2 を含む")
        #expect(ReviewTabText.turnDiffNote(locale: Self.en) == "A turn’s diff is what changed in the worktree during the turn.")
        #expect(ReviewTabText.turnDiffNote(locale: Self.ja) == "ターンの差分は、そのターンの間にワークツリーで起きた変更です。")
        #expect(ReviewTabText.option(.worktreeUnviewedTurns(.none), locale: Self.en) == "Unviewed Turns in the Worktree (None)")
        #expect(ReviewTabText.option(.worktreeUnviewedTurns(.none), locale: Self.ja) == "ワークツリーの未確認のターン（なし）")

        let claude4 = Self.claude(ordinal: 4)
        let option = ReviewScopeOption.unviewedTurns(.none)
        #expect(ReviewTabText.scope(option, conversation: claude4, locale: Self.en) == "Claude #4: Unviewed Turns (None)")
        #expect(ReviewTabText.scope(option, conversation: claude4, locale: Self.ja) == "Claude #4：未確認のターン（なし）")
        #expect(ReviewTabText.scope(option, conversation: nil, locale: Self.en) == "Unviewed Turns (None)")

        let tag = ReviewFileTag(provider: .claude, ordinal: 4, turns: [4, 6])
        #expect(ReviewTabText.fileTag(tag, locale: Self.en) == "Changed during Claude #4’s T4, T6")
        #expect(ReviewTabText.fileTag(tag, locale: Self.ja) == "Claude #4 の T4、T6 の間に変更されました")
        #expect(ReviewTabText.fileTagOrdinal(tag) == "#4")
        #expect(ReviewTabText.fileTagOrdinal(ReviewFileTag(provider: .codex, ordinal: nil, turns: [1])) == nil)
        #expect(ReviewTabText
            .fileTag(ReviewFileTag(provider: .codex, ordinal: nil, turns: [1]), locale: Self.en) == "Changed during Codex’s T1")
    }
}
