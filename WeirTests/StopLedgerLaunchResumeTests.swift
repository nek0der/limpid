// StopLedgerLaunchResumeTests.swift
// Weir — the resume typed at launch is no stop until it fails, and the agent in front at its deadline is the conversation back.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct StopLedgerLaunchResumeTests: StopLedgerFixture {
    /// The resume Weir types at launch is no stop while it is on its way
    /// (every relaunch would list one per pane), and a stop with its own
    /// reason once its command returned to the shell with no run of the
    /// conversation, which offers the resume and a new conversation as any
    /// stop does.
    @Test func aResumeAtLaunch_isListedOnlyOnceItFailed_andThenOffersWhatAStopDoes() throws {
        var ledger = StopLedger()
        let since = Self.start.addingTimeInterval(10)
        ledger.markResumingAtLaunch(paneID: Self.pane, provider: .claude, sessionID: Self.sessionID, cwd: "/tmp/repo", at: since)
        #expect(ledger.retained(besides: []).isEmpty)
        #expect(ledger.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(-1), runTime: 1) == nil)

        let returned = ledger.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(1), runTime: 1)
        #expect(returned == .failed(StopLedger.launchResumeItemID(paneID: Self.pane, sessionID: Self.sessionID)))
        let failed = try #require(returned?.itemID)
        let record = try #require(ledger.record(failed))
        #expect(record.reason == .notResumedAtLaunch)
        #expect(record.resume == .failed)
        #expect(ledger.retained(besides: []).map(\.itemID) == [failed])
        #expect(ledger.launchResumes.isEmpty)
        #expect(StopResumeRules.offer(record: record, job: .shell, hasDraft: false) == .failed)
        #expect(StopResumeRules.command(for: record) == "cd '/tmp/repo' && claude --resume \(Self.sessionID)")
        #expect(StopResumeRules.newConversationCommand(for: record) == "cd '/tmp/repo' && claude")
        // Resumed again from its bar and back: the stop ends as any does.
        ledger.markResuming(failed, at: since.addingTimeInterval(20), window: nil)
        _ = ledger.update(runtimes: [Self.run("b", .running, at: 30, conversation: nil)], paneExists: Self.always)
        #expect(ledger.record(failed) == nil)
    }

    /// The resume typed at launch failed, and the person started the agent
    /// again by hand on a new conversation: the pane moved on, and its bar
    /// no longer says the resume failed over the working agent.
    @Test func aFailedResumeAtLaunch_endsWhenANewConversationStartsInThePane() throws {
        var ledger = StopLedger()
        let since = Self.start.addingTimeInterval(10)
        ledger.markResumingAtLaunch(paneID: Self.pane, provider: .claude, sessionID: Self.sessionID, cwd: "/tmp/repo", at: since)
        let failed = try #require(ledger.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(1), runTime: 1)?
            .itemID)
        #expect(ledger.record(failed) != nil)

        let other = ConversationKey(provider: .claude, conversationID: "c2", isFallback: false)
        _ = ledger.update(runtimes: [Self.run("new", .idle, at: 30, conversation: other, sessionID: "s2")], paneExists: Self.always)
        #expect(ledger.record(failed) == nil)
        #expect(ledger.retained(besides: []).isEmpty)
    }

    /// A run of the session reported after the resume was typed is the
    /// conversation back (or stopped in its own right): the launch resume
    /// is forgotten, and no stop is made of it. The old run's record, read
    /// before the relaunch, is neither.
    @Test func aResumeAtLaunch_whoseSessionReports_isForgotten() {
        var ledger = StopLedger()
        let since = Self.start.addingTimeInterval(10)
        ledger.markResumingAtLaunch(paneID: Self.pane, provider: .claude, sessionID: Self.sessionID, cwd: nil, at: since)
        _ = ledger.update(runtimes: [Self.run("old", .idle, at: 0)], paneExists: Self.always)
        #expect(ledger.launchResumes[Self.pane] != nil)
        _ = ledger.update(runtimes: [Self.run("new", .running, at: 12)], paneExists: Self.always)
        #expect(ledger.launchResumes.isEmpty)
        #expect(ledger.records.isEmpty)
        // Back at the shell later: nothing is left to fail.
        #expect(ledger.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(30), runTime: 1) == nil)
    }

    @Test @MainActor func aResumeAtLaunch_thatNeverComesBack_isAStopAfterItsTime() async {
        let store = StopLedgerStore(resumeTimeout: .milliseconds(50))
        var toldOfTimeout = false
        store.onResumeTimedOut = { toldOfTimeout = true }
        store.markResumingAtLaunch(paneID: Self.pane, provider: .codex, sessionID: Self.sessionID, cwd: nil)
        let id = StopLedger.launchResumeItemID(paneID: Self.pane, sessionID: Self.sessionID)
        // The list is rebuilt while the resume is on its way (the mark
        // itself is one cause): the launch resume has no stop yet, and its
        // clock is what makes one, so the pass must leave it running.
        _ = store.update(runtimes: [Self.run("old", .idle, at: 0)], paneExists: Self.always)
        #expect(store.hasResumeClock)
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(10)) { store.ledger.record(id) != nil }
        #expect(store.ledger.record(id)?.reason == .notResumedAtLaunch)
        #expect(store.ledger.record(id)?.resume == .failed)
        #expect(toldOfTimeout)
        #expect(!store.hasResumeClock)
    }

    /// The agent is in front of the pane at the deadline: the conversation
    /// is back, whether or not its run reported (Codex reports nothing
    /// until its first prompt), so the stop ends and is not made again
    /// from the old run's error. Back at the shell with no run, it failed.
    @Test func aResumeWithTheAgentInFrontAtItsDeadline_isBack_andOneAtTheShell_failed() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        ledger.markResuming(id, at: Self.start, window: nil)
        ledger.resumeTimedOut(id, since: Self.start, isAgentInFront: true)
        #expect(ledger.record(id) == nil)
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        #expect(ledger.record(id) == nil)
        #expect(ledger.retained(besides: []).isEmpty)
        // The person typed on later: nothing is left to end or to fail.
        let resumed = ledger.update(runtimes: [Self.run("d", .idle, at: 90)], paneExists: Self.always).resumed
        #expect(resumed.isEmpty)
        #expect(ledger.resumeCommandFinished(inPane: Self.pane, startedAt: Self.start.addingTimeInterval(1), runTime: 1) == nil)

        var stranded = StopLedger()
        _ = stranded.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        stranded.markResuming(id, at: Self.start, window: nil)
        stranded.resumeTimedOut(id, since: Self.start, isAgentInFront: false)
        #expect(StopResumeRules.offer(record: stranded.record(id), job: .shell, hasDraft: false) == .failed)
    }

    /// The resume typed at launch, with the agent in front of the pane at
    /// its deadline, took: an agent may run no hook until the person
    /// prompts (as `codex resume` does), so no run of the session reports
    /// in time, or at all. No stop is made of it, the stop it took
    /// over from the last launch ends, and the command's later return to
    /// the shell (the person quit the agent) finds nothing to fail.
    @Test func aResumeAtLaunch_withTheAgentInFrontAtItsDeadline_isNoStop() throws {
        var ledger = StopLedger(
            restoring: [
                StopLedger.Record(
                    itemID: StopLedger.itemID(of: Self.run("old", .error)),
                    runtimeID: "old",
                    provider: .claude,
                    paneID: Self.pane,
                    conversation: Self.conversation,
                    sessionID: Self.sessionID,
                    cwd: nil,
                    turnID: nil,
                    reason: .processExited,
                    stoppedAt: Self.start
                )
            ],
            dismissed: []
        )
        let since = Self.start.addingTimeInterval(10)
        ledger.markResumingAtLaunch(paneID: Self.pane, provider: .claude, sessionID: Self.sessionID, cwd: nil, at: since)
        // Nothing reported since the resume was typed.
        _ = ledger.update(runtimes: [], paneExists: Self.always)
        ledger.launchResumeTimedOut(paneID: Self.pane, since: since, isAgentInFront: true)
        #expect(ledger.launchResumes.isEmpty)
        #expect(ledger.records.isEmpty)
        #expect(ledger.retained(besides: []).isEmpty)
        #expect(ledger.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(60), runTime: 1) == nil)

        // The shell in front instead: the stop of the failed resume, as before.
        var failed = StopLedger()
        failed.markResumingAtLaunch(paneID: Self.pane, provider: .codex, sessionID: Self.sessionID, cwd: nil, at: since)
        failed.launchResumeTimedOut(paneID: Self.pane, since: since, isAgentInFront: false)
        let stop = try #require(failed.record(StopLedger.launchResumeItemID(paneID: Self.pane, sessionID: Self.sessionID)))
        #expect(stop.reason == .notResumedAtLaunch)
    }

    /// The store asks the app whether the agent is in front when the
    /// deadline comes, not before: the resume is forgotten with no stop
    /// and no clock, and the bar's resume ends its stop the same way.
    @Test @MainActor func theStore_readsTheJobInFront_atTheDeadline() async {
        let store = StopLedgerStore(resumeTimeout: .milliseconds(50))
        var asked: [(UUID, AgentKind)] = []
        store.isAgentInFront = { paneID, agent in
            asked.append((paneID, agent))
            return true
        }
        store.markResumingAtLaunch(paneID: Self.pane, provider: .codex, sessionID: Self.sessionID, cwd: nil)
        #expect(asked.isEmpty)
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(10)) { !store.hasResumeClock }
        #expect(asked.map(\.0) == [Self.pane])
        #expect(asked.map(\.1) == [.codex])
        #expect(store.ledger.launchResumes.isEmpty)
        #expect(store.ledger.records.isEmpty)

        _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        store.markResuming(id, window: nil)
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(10)) { store.ledger.record(id) == nil }
        #expect(asked.count == 2)
        #expect(asked.last?.1 == .claude)
        #expect(store.ledger.record(id) == nil)
        #expect(!store.hasResumeClock)
    }

    /// A Codex resume that showed its conversation, which the person read
    /// and quit without a prompt before the deadline: no run reported
    /// (Codex's hook waits for the first turn), and its command came back
    /// to the shell. It ran past the time a failed resume takes, so it came
    /// back, and is no stop: neither the launch's nor a bar's. One back as
    /// quickly as a failed resume is one.
    @Test func aResumeThatRanPastAFailedOnesTime_andWasQuit_cameBack_andIsNoStop() {
        let since = Self.start.addingTimeInterval(10)
        let longRun = StopLedger.failedResumeRunTime + 10
        var launch = StopLedger()
        launch.markResumingAtLaunch(paneID: Self.pane, provider: .codex, sessionID: Self.sessionID, cwd: nil, at: since)
        let launchStop = StopLedger.launchResumeItemID(paneID: Self.pane, sessionID: Self.sessionID)
        let launchEnd = launch.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(1), runTime: longRun)
        #expect(launchEnd == .cameBack(launchStop))
        #expect(launch.launchResumes.isEmpty)
        #expect(launch.records.isEmpty)

        var bar = StopLedger()
        _ = bar.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        bar.markResuming(id, at: since, window: nil)
        let barEnd = bar.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(1), runTime: longRun)
        #expect(barEnd == .cameBack(id))
        #expect(bar.record(id) == nil)
        // The old run still in error does not make the stop again.
        _ = bar.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        #expect(bar.record(id) == nil)

        var quick = StopLedger()
        quick.markResumingAtLaunch(paneID: Self.pane, provider: .codex, sessionID: Self.sessionID, cwd: nil, at: since)
        let ranFor = StopLedger.failedResumeRunTime - 1
        let quickEnd = quick.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(1), runTime: ranFor)
        #expect(quickEnd == .failed(launchStop))
        #expect(quick.record(launchStop)?.resume == .failed)
    }

    /// The store reads the run time from the shell's report, and a resume
    /// that came back takes its deadline with it: nothing fails it later.
    @Test @MainActor func theStore_endsAResumeThatCameBack_withItsDeadline() {
        let store = StopLedgerStore(resumeTimeout: .seconds(45))
        let typedAt = Self.start.addingTimeInterval(10)
        store.markResumingAtLaunch(paneID: Self.pane, provider: .codex, sessionID: Self.sessionID, cwd: nil, now: typedAt)
        #expect(store.hasResumeClock)
        let end = store.resumeCommandFinished(
            inPane: Self.pane, exitCode: 130, durationNs: 20_000_000_000, now: typedAt.addingTimeInterval(21)
        )
        #expect(end == .cameBack(StopLedger.launchResumeItemID(paneID: Self.pane, sessionID: Self.sessionID)))
        #expect(store.ledger.records.isEmpty)
        #expect(store.ledger.launchResumes.isEmpty)
        #expect(!store.hasResumeClock)
    }
}
