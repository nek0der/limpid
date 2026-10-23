// StopLedgerTests.swift
// Limpid — a stop stays until its conversation is back, and "Resume Same Conversation" resumes it without a fresh start.

import Foundation
import Testing
@testable import Limpid

struct StopLedgerTests: StopLedgerFixture {
    /// A session never prompted has no transcript, so its stop offers no
    /// resume (one could only fail) but still a new conversation; the
    /// launch rules retire such a run rather than resume it, and the stop
    /// kept across the relaunch must agree. One that says nothing, or was
    /// prompted, offers the resume as before.
    @Test func aStopOfASessionNeverPrompted_offersANewConversation_notAResume() throws {
        var ledger = StopLedger()
        var never = Self.run("a", .error)
        never.hasPrompt = false
        _ = ledger.update(runtimes: [never], paneExists: Self.always, cwd: { _ in "/tmp/repo" })
        let record = try #require(ledger.record(StopLedger.itemID(of: never)))
        #expect(record.sessionID == nil)
        #expect(StopResumeRules.offer(record: record, job: .shell, hasDraft: false) == .unavailable)
        #expect(StopResumeRules.newConversationCommand(for: record) == "cd '/tmp/repo' && claude")
        // Reported again, it still has nothing to resume.
        _ = ledger.update(runtimes: [never], paneExists: Self.always)
        #expect(ledger.record(StopLedger.itemID(of: never))?.sessionID == nil)

        for hasPrompt in [true, nil] as [Bool?] {
            var other = StopLedger()
            var run = Self.run("b", .error)
            run.hasPrompt = hasPrompt
            _ = other.update(runtimes: [run], paneExists: Self.always)
            #expect(other.record(StopLedger.itemID(of: run))?.sessionID == Self.sessionID)
        }
    }

    @Test func aRunInError_isAStop_thatStaysAfterTheRunIsGone() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        #expect(ledger.record(id)?.reason == .error("overloaded"))
        // Listed by the run itself while it says so.
        #expect(ledger.retained(besides: [Self.run("a", .error)]).isEmpty)

        // The agent exited, and its record was cleaned up.
        _ = ledger.update(runtimes: [], paneExists: Self.always)
        #expect(ledger.retained(besides: []).map(\.itemID) == [id])
        // The run's end (`unknown`) is no return either.
        _ = ledger.update(runtimes: [Self.run("a", .unknown, at: 5)], paneExists: Self.always)
        #expect(ledger.record(id) != nil)
    }

    /// A run whose process died at work is in error for the one pass the
    /// projection shows it before its record is retired. The stop is
    /// the process's exit, and it keeps what the resume needs after the run
    /// is gone.
    @Test func aRunWhoseProcessDied_isAStopThatKeepsItsResume_afterItsOnePass() throws {
        let json = #"{"state":"error","updatedAt":"2026-10-13T05:00:00Z","stopReason":"processExited"}"#
        let badge = try JSONDecoder().decode(AgentProjectedBadge.self, from: Data(json.utf8)).asAgentBadge
        var exited = Self.run("a", .error, turn: "T1")
        exited.hasProcessExited = badge.hasProcessExited
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [exited], paneExists: Self.always, cwd: { _ in "/repo" })
        _ = ledger.update(runtimes: [], paneExists: Self.always)

        let kept = ledger.retained(besides: [])
        #expect(kept.map(\.reason) == [.processExited])
        #expect(kept.first?.sessionID == Self.sessionID)
        #expect(kept.first?.cwd == "/repo")
        #expect(kept.first?.turnID == TurnID("T1"))
    }

    @Test func theSameRunActiveAgain_endsTheStop() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        // Typed on in the TUI, in the same second.
        let resumed = ledger.update(runtimes: [Self.run("a", .running, episode: "2")], paneExists: Self.always)
        #expect(ledger.records.isEmpty)
        #expect(resumed.isEmpty)
    }

    @Test func anotherRunOfTheSameConversation_endsTheStop_andAResumeSaysSo() {
        var ledger = StopLedger()
        let window = WindowID()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        ledger.markResuming(id, at: Self.start.addingTimeInterval(10), window: window)

        // A run of another conversation, or one from before the stop, is not it.
        let other = ConversationKey(provider: .claude, conversationID: "c2", isFallback: false)
        _ = ledger.update(runtimes: [Self.run("b", .idle, at: 20, conversation: other, sessionID: "x")], paneExists: Self.always)
        _ = ledger.update(runtimes: [Self.run("c", .idle, at: -5)], paneExists: Self.always)
        #expect(ledger.record(id) != nil)

        let resumed = ledger.update(runtimes: [Self.run("d", .idle, at: 30)], paneExists: Self.always)
        #expect(ledger.record(id) == nil)
        #expect(resumed == [.init(paneID: Self.pane, window: window)])
    }

    @Test func aResumeWhoseRunAlreadyBeganATurn_saysSo() {
        let window = WindowID()
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error, turn: "t1")], paneExists: Self.always)
        ledger.markResuming(StopLedger.itemID(of: Self.run("a", .error)), at: Self.start.addingTimeInterval(10), window: window)
        // The new run was seen only once the person had typed on.
        let resumed = ledger.update(runtimes: [Self.run("d", .running, at: 30, turn: "n1")], paneExists: Self.always)
        #expect(resumed == [.init(paneID: Self.pane, window: window, hasBegunATurn: true)])

        // The stopped run itself back, still on the turn it stopped in, has not.
        var same = StopLedger()
        _ = same.update(runtimes: [Self.run("a", .error, turn: "t1")], paneExists: Self.always)
        same.markResuming(StopLedger.itemID(of: Self.run("a", .error)), at: Self.start.addingTimeInterval(10), window: window)
        let back = same.update(runtimes: [Self.run("a", .idle, at: 30, episode: "2", turn: "t1")], paneExists: Self.always)
        #expect(back == [.init(paneID: Self.pane, window: window)])
    }

    @Test func closingThePane_endsTheStop() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        _ = ledger.update(runtimes: []) { _ in false }
        #expect(ledger.records.isEmpty)
    }

    @Test func aNewerStopOfTheConversationInThePane_replacesTheOlder() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        _ = ledger.update(runtimes: [Self.run("b", .error, at: 50, episode: "9")], paneExists: Self.always)
        #expect(ledger.records.keys.map(\.self) == [StopLedger.itemID(of: Self.run("b", .error, episode: "9"))])
    }

    /// Two runs of the same agent in one pane (two tmux sessions attached
    /// there, or a run left in its error beside a new one) are two stops:
    /// each row's resume needs its own record, whichever stopped first.
    @Test func twoRunsOfOtherConversationsInThePane_keepAStopEach() {
        let other = ConversationKey(provider: .claude, conversationID: "c2", isFallback: false)
        let first = Self.run("a", .error, turn: "T1")
        let second = Self.run("b", .error, at: 50, episode: "9", conversation: other, sessionID: "s2", turn: "T2")
        for order in [[first, second], [second, first]] {
            var ledger = StopLedger()
            _ = ledger.update(runtimes: [order[0]], paneExists: Self.always)
            _ = ledger.update(runtimes: order, paneExists: Self.always)
            #expect(ledger.records.count == 2)
            #expect(ledger.record(StopLedger.itemID(of: first))?.sessionID == Self.sessionID)
            #expect(ledger.record(StopLedger.itemID(of: second))?.sessionID == "s2")
        }
    }

    @Test func aResumeThatTimedOut_isFailed_butALaterOneIsNotTouched() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let first = Self.start.addingTimeInterval(10)
        let second = Self.start.addingTimeInterval(20)
        ledger.markResuming(id, at: first, window: nil)
        ledger.markResuming(id, at: second, window: nil)
        ledger.resumeTimedOut(id, since: first, isAgentInFront: false)
        #expect(ledger.record(id)?.resume == .resuming(since: second, window: nil))
        ledger.resumeTimedOut(id, since: second, isAgentInFront: false)
        #expect(ledger.record(id)?.resume == .failed)
    }

    /// The resume's command came back to the shell at once (no transcript,
    /// a bad session id): no run of the conversation ever reported, so the
    /// stop is back with its button and says the resume failed.
    @Test func aResumeWhoseCommandReturnedToTheShell_isFailed_andTheStopStays() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let since = Self.start.addingTimeInterval(10)
        ledger.markResuming(id, at: since, window: nil)
        // The command began after the resume was typed, and ran briefly.
        #expect(ledger.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(0.2), runTime: 0.4) == .failed(id))
        #expect(ledger.record(id)?.resume == .failed)
        #expect(StopResumeRules.offer(record: ledger.record(id), job: .shell, hasDraft: false) == .failed)
        // Not a new conversation: the stop and its session stay for the
        // next press.
        #expect(ledger.record(id)?.sessionID == Self.sessionID)
        #expect(ledger.retained(besides: []).map(\.itemID) == [id])
        #expect(ledger.record(id).flatMap(StopResumeRules.command(for:)) != nil)
    }

    @Test func aCommandOfAnotherPane_orOneThatBeganBeforeTheResume_isNotTheResume() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let since = Self.start.addingTimeInterval(10)
        ledger.markResuming(id, at: since, window: nil)
        #expect(ledger.resumeCommandFinished(inPane: UUID(), startedAt: since.addingTimeInterval(1), runTime: 1) == nil)
        #expect(ledger.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(-1), runTime: 1) == nil)
        #expect(ledger.record(id)?.resume == .resuming(since: since, window: nil))
        // A stop with no resume on its way has nothing to fail.
        var untouched = StopLedger()
        _ = untouched.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        #expect(untouched.resumeCommandFinished(inPane: Self.pane, startedAt: since, runTime: 1) == nil)
        #expect(untouched.record(id)?.resume == StopLedger.Resume.none)
    }

    @Test func aStopKeptAfterItsRun_staysOneItem_inTheAttentionList() {
        let run = Self.run("a", .error)
        let (first, effects) = AttentionQueueReducer.reduce(AttentionQueue(), input: .init(runtimes: [run]))
        #expect(first.items.count == 1)
        #expect(!effects.isEmpty)
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [run], paneExists: Self.always)
        _ = ledger.update(runtimes: [], paneExists: Self.always)
        let retained = ledger.retained(besides: []).map { record in
            AttentionQueueReducer.RetainedStop(
                itemID: record.itemID,
                runtimeID: record.runtimeID,
                provider: record.provider,
                paneID: record.paneID,
                tabID: nil,
                projectID: nil,
                reason: record.reason,
                stoppedAt: record.stoppedAt
            )
        }
        let (second, again) = AttentionQueueReducer.reduce(first, input: .init(retainedStops: retained))
        #expect(second.items.map(\.id) == first.items.map(\.id))
        #expect(second.items.first?.subject.paneID == Self.pane)
        // The same item, not a new one to announce.
        #expect(again.isEmpty)
    }

    @Test func aStopOffersTheResume_onlyWithASession_andTheShellInFront_withNothingTyped() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error), Self.run("n", .error, pane: UUID(), sessionID: nil)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let record = ledger.record(id)
        #expect(StopResumeRules.offer(record: record, job: .shell, hasDraft: false) == .available)
        #expect(StopResumeRules.offer(record: record, job: .agent, hasDraft: false) == .unavailable)
        #expect(StopResumeRules.offer(record: record, job: .other, hasDraft: false) == .blocked(.notAtShell))
        #expect(StopResumeRules.offer(record: record, job: .shell, hasDraft: true) == .blocked(.draft))
        let noSession = ledger.record(StopLedger.itemID(of: Self.run("n", .error)))
        #expect(StopResumeRules.offer(record: noSession, job: .shell, hasDraft: false) == .unavailable)
        #expect(StopResumeRules.offer(record: nil, job: .shell, hasDraft: false) == .unavailable)
        ledger.markResuming(id, at: Self.start, window: nil)
        #expect(StopResumeRules.offer(record: ledger.record(id), job: .shell, hasDraft: false) == .resuming)
        ledger.resumeTimedOut(id, since: Self.start, isAgentInFront: false)
        #expect(StopResumeRules.offer(record: ledger.record(id), job: .shell, hasDraft: false) == .failed)
    }

    @Test func whatTheRunReportsLater_isTheStopsToo() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error, sessionID: nil)], paneExists: Self.always)
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        #expect(ledger.records.values.first?.sessionID == Self.sessionID)
    }

    @Test func aConversationBackInAnotherPane_endsTheStop_butSaysNothingInIt() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        ledger.markResuming(id, at: Self.start, window: WindowID())
        let resumed = ledger.update(runtimes: [Self.run("b", .running, at: 30, pane: UUID())], paneExists: Self.always)
        #expect(ledger.records.isEmpty)
        #expect(resumed.isEmpty)
    }

    @Test func aConversationBackInAnotherPane_endsTheStop_whileTheOldRunStillSaysError() {
        var ledger = StopLedger()
        let old = Self.run("a", .error)
        let back = Self.run("b", .running, at: 30, pane: UUID())
        _ = ledger.update(runtimes: [old], paneExists: Self.always)
        // The agent was left in its error in its pane; the conversation was
        // resumed in another, and both report.
        _ = ledger.update(runtimes: [old, back], paneExists: Self.always)
        _ = ledger.update(runtimes: [old, back], paneExists: Self.always)
        #expect(ledger.records.isEmpty)
        let id = StopLedger.itemID(of: old)
        #expect(ledger.dismissed.contains(id))
        // Nor does the list make it again from the old run's error.
        let (queue, _) = AttentionQueueReducer.reduce(
            AttentionQueue(),
            input: .init(runtimes: [old, back], dismissedStops: ledger.dismissed)
        )
        #expect(!queue.items.map(\.id).contains(id))
        // A later error of the old run is a new stop.
        let again = Self.run("a", .error, at: 60, episode: "2")
        _ = ledger.update(runtimes: [again], paneExists: Self.always)
        #expect(ledger.records[StopLedger.itemID(of: again)] != nil)
    }

    @Test(arguments: [("\u{7F}", true), ("\u{9B}", true), ("\t", true), ("/compact", false), ("é", false)])
    func aTypedCommand_carriesNoControlCharacter(_ text: String, _ isControl: Bool) {
        #expect(text.unicodeScalars.contains(where: \.isTypedControl) == isControl)
    }

    @Test func aDismissedStop_isNotKeptAgain_whileItsRunStillSaysSo() {
        var ledger = StopLedger()
        let run = Self.run("a", .error)
        let id = StopLedger.itemID(of: run)
        _ = ledger.update(runtimes: [run], paneExists: Self.always)
        ledger.dismiss(id)
        _ = ledger.update(runtimes: [run], paneExists: Self.always)
        #expect(ledger.records.isEmpty)
        #expect(ledger.dismissed == [id])
        // The attention list leaves it out too.
        let (queue, _) = AttentionQueueReducer.reduce(AttentionQueue(), input: .init(runtimes: [run], dismissedStops: ledger.dismissed))
        #expect(queue.items.isEmpty)
        // Once the run no longer says so, the mark is let go.
        _ = ledger.update(runtimes: [], paneExists: Self.always)
        #expect(ledger.dismissed.isEmpty)
        // A later error of the run is a stop again.
        _ = ledger.update(runtimes: [Self.run("a", .error, at: 60, episode: "2")], paneExists: Self.always)
        #expect(ledger.records.count == 1)
    }

    @Test func theStoppedTurn_isKept_forItsPartialChanges() {
        var ledger = StopLedger()
        var run = Self.run("a", .error)
        _ = ledger.update(runtimes: [run], paneExists: Self.always)
        #expect(ledger.records.values.first?.turnID == nil)
        // Reported again with its turn.
        run.currentTurnID = TurnID("t7")
        _ = ledger.update(runtimes: [run], paneExists: Self.always)
        #expect(ledger.records.values.first?.turnID == TurnID("t7"))
    }

    @Test func aNewConversation_thatCannotStart_saysWhy() {
        #expect(StopResumeRules.newConversationBlocker(job: .shell, hasDraft: false) == nil)
        #expect(StopResumeRules.newConversationBlocker(job: .shell, hasDraft: true) == .draft)
        #expect(StopResumeRules.newConversationBlocker(job: .agent, hasDraft: false) == .notAtShell)
        #expect(StopResumeRules.newConversationBlocker(job: .other, hasDraft: true) == .notAtShell)
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        #expect(StopResumeRules.newConversationHelp(.notAtShell).resolved(in: en)
            == "To start a new conversation, return the pane to its shell prompt.")
        #expect(StopResumeRules.newConversationHelp(.draft).resolved(in: ja)
            == "新しい会話で開始するには、Control-C でプロンプトを空にしてください。")
    }

    /// A fallback conversation key names the pane rather than the
    /// conversation, so on its own it matches nothing: a run is the stopped
    /// conversation back only when the stopped run had a session id and the
    /// new run reports the same one.
    @Test(arguments: [
        (nil, "y"),
        (StopLedgerTests.sessionID, StopLedgerTests.sessionID)
    ] as [(String?, String?)])
    func aFallbackConversation_isBackOnlyBySessionID(stopped: String?, returning: String?) {
        let isBack = stopped != nil && stopped == returning
        var ledger = StopLedger()
        let fallback = ConversationKey(provider: .claude, conversationID: "pane", isFallback: true)
        _ = ledger.update(
            runtimes: [Self.run("a", .error, conversation: fallback, sessionID: stopped)],
            paneExists: Self.always
        )
        _ = ledger.update(
            runtimes: [Self.run("b", .idle, at: 5, conversation: fallback, sessionID: returning)],
            paneExists: Self.always
        )
        #expect(ledger.records.isEmpty == isBack)
    }

    /// The resume and a new conversation both start where the conversation
    /// ran, quoted as typed.
    @Test func bothCommands_runInTheConversationsFolder() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always) { _ in "/tmp/it's here" }
        let record = ledger.record(StopLedger.itemID(of: Self.run("a", .error)))
        #expect(record.flatMap(StopResumeRules.command(for:)) == "cd '/tmp/it'\\''s here' && claude --resume \(Self.sessionID)")
        #expect(record.flatMap(StopResumeRules.newConversationCommand(for:)) == "cd '/tmp/it'\\''s here' && claude")
        // No folder on record: the agent alone, where the shell is.
        var bare = StopLedger()
        _ = bare.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        #expect(bare.record(StopLedger.itemID(of: Self.run("a", .error))).flatMap(StopResumeRules.newConversationCommand(for:)) == "claude")
        // A folder whose name would be keys rather than a name: nothing typed.
        var unsafe = StopLedger()
        _ = unsafe.update(runtimes: [Self.run("a", .error)], paneExists: Self.always) { _ in "/tmp/a\nb" }
        #expect(unsafe.record(StopLedger.itemID(of: Self.run("a", .error))).flatMap(StopResumeRules.newConversationCommand(for:)) == nil)
    }
}
