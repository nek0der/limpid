// ToastKindTests.swift
// Weir — the supervision UI's toasts: what each says, and which offer Undo.

import Foundation
import Testing
@testable import Weir

struct ToastKindTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test(arguments: [
        (ToastKind.windowClosed(projectName: "weir"), false),
        (.testNotificationSent, false),
        (.markedViewed(through: 7), true),
        (.markedViewedInConversations(through: 7, conversation: "Claude #4", others: 1), true),
        (.markedUnviewedInConversations(from: 7, conversation: "Claude #4", others: 1), true),
        (.codeRestored(turnNumber: 7), true),
        (.restoreInterrupted, true),
        (.discardInterrupted, true),
        (.discardSettled, true),
        (.operationsInterrupted(count: 2), true),
        (.undoInterrupted, true),
        (.keptAsideAtQuit, false)
    ])
    func onlyWhatCanBeTakenBack_offersUndo(_ kind: ToastKind, _ offersUndo: Bool) {
        #expect(kind.offersUndo == offersUndo)
    }

    @Test(arguments: [
        (ToastKind.windowClosed(projectName: "weir"), "en", "Closed the window. weir’s agents and terminals keep running."),
        (.windowClosed(projectName: "weir"), "ja", "ウインドウを閉じました。weir のエージェントとターミナルは実行を続けます。"),
        (.testNotificationSent, "en", "Sent a test notification. If it doesn’t arrive, check the macOS notification settings."),
        (.markedViewed(through: 7), "en", "Marked as viewed up to T7."),
        (.markedViewed(through: 7), "ja", "T7 まで確認済みにしました。"),
        (.markedViewed(through: nil), "en", "Marked as viewed."),
        (.markedViewed(through: nil), "ja", "確認済みにしました。"),
        // Whose T7, since every conversation numbers its own; the others
        // as a count in a sentence of their own.
        (
            .markedViewedInConversations(through: 7, conversation: "Claude #4", others: 1), "en",
            "Marked as viewed up to T7 of Claude #4, and 1 other conversation up to the same point."
        ),
        (
            .markedViewedInConversations(through: 7, conversation: "Claude #4", others: 1), "ja",
            "Claude #4 の T7 まで確認済みにしました。ほかの会話 1 件も同じ時点まで確認済みにしました。"
        ),
        (
            .markedViewedInConversations(through: 7, conversation: "Claude #4", others: 2), "en",
            "Marked as viewed up to T7 of Claude #4, and 2 other conversations up to the same point."
        ),
        // 件 counts past nine, where つ stops reading as Japanese.
        (
            .markedViewedInConversations(through: 7, conversation: "Claude #4", others: 13), "ja",
            "Claude #4 の T7 まで確認済みにしました。ほかの会話 13 件も同じ時点まで確認済みにしました。"
        ),
        (
            .markedUnviewedInConversations(from: 7, conversation: "Codex", others: 1), "en",
            "Marked as unviewed from T7 of Codex, and 1 other conversation from the same point."
        ),
        (
            .markedUnviewedInConversations(from: 7, conversation: "Codex", others: 1), "ja",
            "Codex の T7 から未確認にしました。ほかの会話 1 件も同じ時点から未確認にしました。"
        ),
        (.codeRestored(turnNumber: 7), "en", "Restored the code to before T7. Not reflected in the conversation."),
        (.codeRestored(turnNumber: 7), "ja", "コードを T7 の前の状態に復元しました。会話には反映されていません。"),
        (.restoreInterrupted, "en", "A code restore stopped partway when Weir last quit."),
        (.restoreInterrupted, "ja", "前回の終了時に、コードの復元が途中で中断されました。"),
        (.discardInterrupted, "ja", "前回の終了時に、ハンクの破棄が途中で中断されました。"),
        (.discardSettled, "ja", "前回の終了時に、ハンクの破棄が完了しました。"),
        (.operationsInterrupted(count: 2), "ja", "前回の終了時に、コードの復元、ハンクの破棄、または取り消しが 2 件実行中でした。")
    ])
    func eachToast_saysWhatHappened(_ kind: ToastKind, _ language: String, _ message: String) {
        #expect(kind.message.resolved(in: Locale(identifier: language)) == message)
    }

    @Test func aToastAcrossConversations_saysItsUndoCountsThemAll() {
        let across = ToastKind.markedViewedInConversations(through: 7, conversation: "Claude #4", others: 1)
        #expect(across.undoLabel?.resolved(in: Self.english) == "Undo in 2 Conversations")
        #expect(across.undoLabel?.resolved(in: Self.japanese) == "会話 2 件をまとめて元に戻す")
        let many = ToastKind.markedViewedInConversations(through: 7, conversation: "Claude #4", others: 13)
        #expect(many.undoLabel?.resolved(in: Self.japanese) == "会話 14 件をまとめて元に戻す")
        #expect(ToastKind.markedViewed(through: 7).undoLabel == nil, "Undo says it")
    }

    @Test @MainActor func aToastFromElsewhere_hasNoUndo_andAReversibleOneCarriesIt() {
        #expect(ToastItem(.windowClosed(projectName: "weir")).undo == nil)
        #expect(ToastItem(.testNotificationSent).undo == nil)

        var undone = false
        let reversible = ToastItem(.markedViewed(through: 7)) { undone = true }
        reversible.undo?()
        #expect(undone)
    }

    @Test @MainActor func aToastTakenBackElsewhere_goes_butNotAnotherThatReplacedIt() {
        let center = ToastCenter()
        let window = WindowID()
        let id = UUID()
        center.show(ToastItem(.markedViewed(through: 7), id: id) {}, in: window)
        center.dismiss(id)
        #expect(center.current(in: window) == nil)

        center.show(ToastItem(.markedViewed(through: 7), id: id) {}, in: window)
        center.show(ToastItem(.testNotificationSent), in: window)
        center.dismiss(id)
        #expect(center.current(in: window) != nil, "a newer toast stays")
    }
}
