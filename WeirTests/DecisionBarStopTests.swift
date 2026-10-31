// DecisionBarStopTests.swift
// Weir — what an agent pane's decision bar says of a stopped agent: its menu, its resume, and the line once it is back.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct DecisionBarStopTests {
    private static let pane = UUID()

    @Test func aStoppedBar_offersItsMenu_butNotWhileResuming() {
        let item = AttentionItem.testStop(pane: Self.pane)
        let stopped = DecisionBarModel(content: .make(.init(items: [item])), locale: Locale(identifier: "en"))
        #expect(stopped.stopItem == item.id)
        let resuming = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .resuming])),
            locale: Locale(identifier: "en")
        )
        #expect(resuming.stopItem == nil)
    }

    @Test func aPaneKeepsItsBar_whileAStopOfItsAgentWaits() {
        let item = AttentionItem.testStop(pane: Self.pane)
        #expect(DecisionBarModel.stoppedAgent(in: [item])?.provider == .claude)
        #expect(DecisionBarModel.stoppedAgent(in: []) == nil)
    }

    @Test func theBar_offersTheResume_saysItIsResuming_andThatItIsBack() {
        let item = AttentionItem.testStop(pane: Self.pane)
        let english = Locale(identifier: "en")
        let available = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .available])),
            locale: english
        )
        #expect(available.primaryAction == .resume(item.id))
        #expect(available.text == "The process exited unexpectedly. The conversation is saved.")

        let failed = DecisionBarModel(content: .make(.init(items: [item], stopResumes: [item.id: .failed])), locale: english)
        #expect(failed.primaryAction == .resume(item.id))
        #expect(failed.text.hasSuffix("Couldn’t resume the same conversation. Its terminal shows why."))
        let failedInJapanese = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .failed])),
            locale: Locale(identifier: "ja")
        )
        #expect(failedInJapanese.text.hasSuffix("同じ会話を再開できませんでした。理由はターミナルに表示されています。"))

        let unavailable = DecisionBarModel(content: .make(.init(items: [item])), locale: english)
        #expect(unavailable.primaryAction == nil)
        #expect(unavailable.text == "The process exited unexpectedly.")

        let resuming = DecisionBarModel(content: .make(.init(items: [item], stopResumes: [item.id: .resuming])), locale: english)
        #expect(resuming.tag == "Resuming")
        #expect(resuming.text == "Loading the same conversation…")
        #expect(resuming.primaryAction == nil)

        let back = DecisionBarModel(content: .make(.init(done: .init(result: .resumed, next: nil))), locale: Locale(identifier: "ja"))
        #expect(back.text == "同じ会話を再開しました。続きの指示はターミナルで入力してください。")

        let japanese = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .available])),
            locale: Locale(identifier: "ja")
        )
        // Japanese sentences run on with no space, as the restore strip's
        // do; an agent's own words, in English, keep one after them.
        #expect(japanese.text == "プロセスが異常終了しました。会話は保存されています。")
        let agentsError = AttentionItem.testStop(pane: Self.pane, reason: .error("API Error: overloaded"))
        let agentsErrorInJapanese = DecisionBarModel(
            content: .make(.init(items: [agentsError], stopResumes: [agentsError.id: .available])),
            locale: Locale(identifier: "ja")
        )
        #expect(agentsErrorInJapanese.text == "API Error: overloaded 会話は保存されています。")

        let blocked = DecisionBarModel(content: .make(.init(items: [item], stopResumes: [item.id: .blocked(.draft)])), locale: english)
        #expect(blocked.primaryAction == nil)
        #expect(blocked.text.hasSuffix("To resume it, clear the prompt with Control-C."))

        // Back with its unread turns: the line shows over them.
        let unread = AttentionItem.testUnread(pane: Self.pane)
        #expect(DecisionBarContent.takes(.resumed, over: [unread]))
        #expect(!DecisionBarContent.takes(.resumed, over: [item]))
    }

    /// The resume typed at relaunch failing is said once: what failed and
    /// where to look, not the list's reason followed by the same failure
    /// in other words. Resuming it again from the bar is said as any is.
    @Test func theBar_saysAFailedRelaunchResume_once() {
        let item = AttentionItem.testStop(pane: Self.pane, reason: .notResumedAtLaunch)
        let failed = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .failed])),
            locale: Locale(identifier: "en")
        )
        #expect(failed.text == "Couldn’t resume the same conversation after Weir relaunched. Its terminal shows why.")
        #expect(failed.primaryAction == .resume(item.id))
        let japanese = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .failed])),
            locale: Locale(identifier: "ja")
        )
        #expect(japanese.text.hasPrefix("Weir の再起動後に同じ会話を再開できませんでした。"))
        #expect(japanese.text.hasSuffix("理由はターミナルに表示されています。"))
        #expect(!japanese.text.contains("再開できていません"))
        let resuming = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .resuming])),
            locale: Locale(identifier: "en")
        )
        #expect(resuming.text == "Loading the same conversation…")
    }
}
