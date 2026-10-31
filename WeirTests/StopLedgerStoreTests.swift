// StopLedgerStoreTests.swift
// Weir — a stop that exists at quit exists after the relaunch: stops.json.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// The stops kept across launches (`StopLedgerStore`). The ledger's own
/// rules are in `StopLedgerTests`; here what the store adds: the file, and
/// the clock a resume runs against.
@MainActor
struct StopLedgerStoreTests: StopLedgerFixture {
    /// A stop that exists at quit exists after the relaunch: the run
    /// that died was retired with its record, so the file is all that says
    /// the pane holds a conversation that stopped. It offers the same
    /// resume and a new conversation as before the quit.
    @Test func aStop_staysAcrossALaunch_withItsSessionAndFolder() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let exited = Self.run("a", .error, at: 0, turn: "t1")
            _ = store.update(runtimes: [exited], paneExists: Self.always, cwd: { _ in "/tmp/repo" })
            let id = StopLedger.itemID(of: exited)
            // The run's record is retired: the stop is the ledger's alone.
            _ = store.update(runtimes: [], paneExists: Self.always)
            store.flushSynchronously()

            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let record = try #require(relaunched.ledger.record(id))
            #expect(record.runtimeID == "a")
            #expect(record.paneID == Self.pane)
            #expect(record.sessionID == Self.sessionID)
            #expect(record.cwd == "/tmp/repo")
            #expect(record.conversation == Self.conversation)
            #expect(record.turnID == TurnID("t1"))
            #expect(record.reason == .error("overloaded"))
            #expect(record.stoppedAt == Self.start)
            #expect(record.resume == StopLedger.Resume.none)
            // Listed from the file, with nothing reporting it.
            _ = relaunched.update(runtimes: [], paneExists: Self.always)
            #expect(relaunched.ledger.retained(besides: []).map(\.itemID) == [id])
            #expect(StopResumeRules.offer(record: record, job: .shell, hasDraft: false) == .available)
            #expect(StopResumeRules.command(for: record) == "cd '/tmp/repo' && claude --resume \(Self.sessionID)")
            #expect(StopResumeRules.newConversationCommand(for: record) == "cd '/tmp/repo' && claude")
        }
    }

    /// The ways a stop ends are kept too: one the person moved on from
    /// stays dismissed when its run still says error after the relaunch,
    /// and one whose pane the session did not restore ends at the first
    /// look. A resume on its way at quit is no longer on its way: the
    /// shell it was typed into went with the launch, so the stop offers
    /// the resume afresh; a resume that had failed still says so.
    @Test func aStopsEnd_andItsResume_areKeptAcrossALaunch() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let gonePane = UUID()
            let dismissedRun = Self.run("dismissed", .error, at: 0, episode: "1", pane: UUID(), sessionID: "s-dismissed")
            let resumingRun = Self.run("resuming", .error, at: 1, episode: "1", pane: gonePane, sessionID: "s-resuming")
            let failedRun = Self.run("failed", .error, at: 2, episode: "1", sessionID: "s-failed")
            _ = store.update(runtimes: [dismissedRun, resumingRun, failedRun], paneExists: Self.always)
            let dismissed = StopLedger.itemID(of: dismissedRun)
            let resuming = StopLedger.itemID(of: resumingRun)
            let failed = StopLedger.itemID(of: failedRun)
            store.dismiss(dismissed)
            store.markResuming(resuming, window: WindowID(), now: Self.start.addingTimeInterval(10))
            store.markResuming(failed, window: nil, now: Self.start.addingTimeInterval(10))
            let returned = store.resumeCommandFinished(
                inPane: Self.pane, exitCode: 1, durationNs: 1, now: Self.start.addingTimeInterval(12)
            )
            #expect(returned == .failed(failed))
            store.flushSynchronously()

            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(relaunched.ledger.dismissed == [dismissed])
            #expect(relaunched.ledger.record(resuming)?.resume == StopLedger.Resume.none)
            #expect(relaunched.ledger.record(failed)?.resume == .failed)
            #expect(!relaunched.hasResumeClock)
            // The dismissed run still in error lists nothing; the pane the
            // session did not bring back takes its stop with it.
            _ = relaunched.update(runtimes: [dismissedRun], paneExists: { $0 != gonePane })
            #expect(relaunched.ledger.record(dismissed) == nil)
            #expect(relaunched.ledger.dismissed == [dismissed])
            #expect(relaunched.ledger.record(resuming) == nil)
            #expect(relaunched.ledger.retained(besides: [dismissedRun]).map(\.itemID) == [failed])
            // The ends are saved too; written before the folder goes.
            relaunched.flushSynchronously()
            #expect(StopLedgerStore(directory: dir, resumeTimeout: .seconds(30)).ledger.records.keys.contains(failed))
        }
    }

    /// A stop that ended is gone from the file as well, and the debounced
    /// save lands without a flush, as the app relies on between launches.
    @Test func aStopThatEnded_leavesTheFile() async throws {
        try await withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
            let id = StopLedger.itemID(of: Self.run("a", .error))
            // The file itself is the signal. The deadline is only for a save
            // that never comes: the save waits on the main queue, which a
            // parallel run can stall.
            await pollUntil(timeout: .seconds(30), interval: .milliseconds(20)) {
                StopLedgerStore(directory: dir, resumeTimeout: .seconds(30)).ledger.record(id) != nil
            }
            #expect(StopLedgerStore(directory: dir, resumeTimeout: .seconds(30)).ledger.record(id) != nil)

            // The conversation came back: the stop ends, on disk too.
            _ = store.update(runtimes: [Self.run("b", .running, at: 30)], paneExists: Self.always)
            store.flushSynchronously()
            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(relaunched.ledger.records.isEmpty)
        }
    }

    /// A stop that began and ended while its write was under way is not
    /// left on disk by the flush at quit: the file held no stops before,
    /// and holds none after, but the write under way carries the stop, so
    /// the flush writes the ledger after it whatever the file held.
    @Test func aStopThatEndedWhileItsWriteWasUnderWay_isNotLeftByTheFlush() async throws {
        try await withTempDir { dir in
            let queue = DispatchQueue(label: "com.nekoder.weir.stop-ledger.test")
            let gate = DispatchSemaphore(value: 0)
            // Holds the store's write behind ours until the flush.
            queue.async { gate.wait() }
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30), saveQueue: queue)
            let stopped = Self.run("a", .error)
            _ = store.update(runtimes: [stopped], paneExists: Self.always)
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { store.hasWriteUnderWay }
            #expect(store.hasWriteUnderWay)

            // The conversation came back: the ledger is as the file was.
            _ = store.update(runtimes: [Self.run("b", .running, at: 30)], paneExists: Self.always)
            #expect(store.ledger.records.isEmpty)
            gate.signal()
            store.flushSynchronously()

            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(relaunched.ledger.record(StopLedger.itemID(of: stopped)) == nil)
        }
    }

    /// A file from a newer build is read for the stops it can give and
    /// left as it is; a record this build cannot read costs that record,
    /// not the file.
    @Test func aNewerOrPartlyUnreadableFile_costsOnlyWhatCannotBeRead() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
            let id = StopLedger.itemID(of: Self.run("a", .error))
            store.flushSynchronously()
            let file = dir.appendingPathComponent("stops.json")
            let written = try String(contentsOf: file, encoding: .utf8)
            // One record this build cannot read, beside the known one. The
            // edits match the encoder's spacing: one that matched nothing
            // would leave a file with nothing unreadable or newer in it.
            let text = written.replacingOccurrences(of: "\"records\" : [", with: "\"records\" : [{\"kind\":\"later\"},")
            #expect(text != written)
            try text.data(using: .utf8).map { try $0.write(to: file) }
            #expect(StopLedgerStore(directory: dir, resumeTimeout: .seconds(30)).ledger.record(id) != nil)

            let newer = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
            #expect(newer != text)
            try newer.data(using: .utf8).map { try $0.write(to: file) }
            let later = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(later.ledger.record(id) != nil)
            later.dismiss(id)
            later.flushSynchronously()
            #expect(try String(contentsOf: file, encoding: .utf8) == newer)
        }
    }

    /// Demo mode, and the ledger's own tests, keep the stops in memory:
    /// nothing is read from or written to the person's folder.
    @Test func aStoreThatWritesNoFiles_touchesNone() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, writesFiles: false, resumeTimeout: .seconds(30))
            _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
            store.flushSynchronously()
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("stops.json").path))
        }
    }

    /// A run alive in error at quit (a usage limit) is killed by Weir
    /// and resumed at launch, while its stop comes back from the
    /// file: one stop of the conversation, which says it is resuming
    /// rather than offering a second resume, and which the launch's own
    /// stop replaces if that resume fails. Back, it ends as any does.
    @Test func aStopKeptFromTheLastLaunch_isTheLaunchResumesToResume_notASecondOne() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let limited = Self.run("a", .error)
            _ = store.update(runtimes: [limited], paneExists: Self.always, cwd: { _ in "/tmp/repo" })
            let kept = StopLedger.itemID(of: limited)
            store.flushSynchronously()

            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let typedAt = Self.start.addingTimeInterval(100)
            relaunched.markResumingAtLaunch(
                paneID: Self.pane, provider: .claude, sessionID: Self.sessionID, cwd: "/tmp/repo", now: typedAt
            )
            let taken = try #require(relaunched.ledger.record(kept))
            #expect(taken.resume == .resuming(since: typedAt, window: nil))
            #expect(StopResumeRules.offer(record: taken, job: .shell, hasDraft: false) == .resuming)
            // Another session's stop in the pane is not the launch's.
            var other = relaunched.ledger
            let otherRun = Self.run("b", .error, at: 1, sessionID: "other")
            _ = other.update(runtimes: [otherRun], paneExists: Self.always)
            #expect(other.record(StopLedger.itemID(of: otherRun))?.resume == StopLedger.Resume.none)

            // The resume returned to the shell: one stop in the pane, the
            // launch's, offering the resume and a new conversation again.
            let launchStop = StopLedger.launchResumeItemID(paneID: Self.pane, sessionID: Self.sessionID)
            let failed = relaunched.resumeCommandFinished(
                inPane: Self.pane, exitCode: 1, durationNs: 1, now: typedAt.addingTimeInterval(2)
            )
            #expect(failed == .failed(launchStop))
            #expect(relaunched.ledger.record(kept) == nil)
            let stops = relaunched.ledger.records.values.filter { $0.paneID == Self.pane }
            #expect(stops.map(\.itemID) == [launchStop])
            #expect(stops.first?.reason == .notResumedAtLaunch)
            #expect(stops.first?.cwd == "/tmp/repo")
            relaunched.flushSynchronously()
            #expect(StopLedgerStore(directory: dir, resumeTimeout: .seconds(30)).ledger.record(launchStop) != nil)

            // Or the conversation came back: the kept stop ends with it.
            let again = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            again.markResumingAtLaunch(paneID: Self.pane, provider: .claude, sessionID: Self.sessionID, cwd: nil, now: typedAt)
            _ = again.update(runtimes: [Self.run("c", .running, at: 200)], paneExists: Self.always)
            #expect(again.ledger.records.isEmpty)
            #expect(again.ledger.launchResumes.isEmpty)
            again.flushSynchronously()
        }
    }

    /// A launch whose session did not come back from its file has no
    /// panes for the stops to be in, through no doing of the person's:
    /// they are kept, in memory and in the file, for the launch that
    /// restores the session, rather than written away as pane-less.
    @Test func aLaunchWithoutItsSession_keepsTheStops_andTheirFile() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
            let id = StopLedger.itemID(of: Self.run("a", .error))
            store.flushSynchronously()

            let broken = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            broken.keepsStopsWithoutPanes = true
            _ = broken.update(runtimes: [], paneExists: { _ in false })
            #expect(broken.ledger.record(id) != nil)
            broken.flushSynchronously()

            let restored = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(restored.ledger.record(id) != nil)
            // With the session back, a pane that is gone ends its stop as before.
            _ = restored.update(runtimes: [], paneExists: { _ in false })
            #expect(restored.ledger.record(id) == nil)
            restored.flushSynchronously()
        }
    }

    /// Makes `dir` read-only, as a managed or restored Mac can leave it, so
    /// no write of the file lands there; or writable again.
    private static func setWritable(_ dir: URL, _ isWritable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: isWritable ? 0o700 : 0o500], ofItemAtPath: dir.path)
    }

    /// A write that failed is not taken for written: the flush at quit
    /// writes the same stops once the file can be written.
    @Test func aFailedWrite_isWrittenByTheFlushAtQuit() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30), retryDelay: .seconds(60))
            try Self.setWritable(dir, false)
            defer { try? Self.setWritable(dir, true) }
            let stopped = Self.run("a", .error)
            _ = store.update(runtimes: [stopped], paneExists: Self.always)
            store.flushSynchronously()
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("stops.json").path))
            try Self.setWritable(dir, true)
            store.flushSynchronously()
            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(relaunched.ledger.record(StopLedger.itemID(of: stopped)) != nil)
        }
    }

    /// A write that failed on its own (no quit to flush it) is tried
    /// again, and lands once the file can be written.
    @Test func aFailedWrite_isTriedAgain() async throws {
        try await withTempDir { dir in
            let queue = DispatchQueue(label: "com.nekoder.weir.stop-ledger.retry-test")
            let gate = DispatchSemaphore(value: 0)
            // Holds the first write on the save queue until we let it land.
            queue.async { gate.wait() }
            let store = StopLedgerStore(
                directory: dir, resumeTimeout: .seconds(30), retryDelay: .milliseconds(100), saveQueue: queue
            )
            try Self.setWritable(dir, false)
            defer { try? Self.setWritable(dir, true) }
            let stopped = Self.run("a", .error)
            _ = store.update(runtimes: [stopped], paneExists: Self.always)
            // Past the coalescing delay the first write goes to the queue;
            // let it land, and fail.
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { store.hasWriteUnderWay }
            #expect(store.hasWriteUnderWay)
            gate.signal()
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { !store.hasWriteUnderWay }
            let file = dir.appendingPathComponent("stops.json")
            #expect(!FileManager.default.fileExists(atPath: file.path))
            try Self.setWritable(dir, true)
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                FileManager.default.fileExists(atPath: file.path)
            }
            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(relaunched.ledger.record(StopLedger.itemID(of: stopped)) != nil)
        }
    }

    // MARK: - The resume clock

    /// The resume brought the conversation back: its run reported, the stop
    /// ended as before, and the command's later return to the shell (the
    /// person quit the agent) finds no resume to fail.
    @Test func aResumeWhoseConversationCameBack_endsTheStop_andItsLaterExitTouchesNothing() {
        let store = StopLedgerStore(resumeTimeout: .seconds(30))
        _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let window = WindowID()
        store.markResuming(id, window: window, now: Self.start.addingTimeInterval(10))
        let resumed = store.update(runtimes: [Self.run("d", .idle, at: 30)], paneExists: Self.always).resumed
        #expect(resumed == [.init(paneID: Self.pane, window: window)])
        #expect(store.ledger.records.isEmpty)
        #expect(!store.hasResumeClock)
        let exited = store.resumeCommandFinished(
            inPane: Self.pane, exitCode: 0, durationNs: 5_000_000_000, now: Self.start.addingTimeInterval(60)
        )
        #expect(exited == nil)
    }

    /// The command's start is its end less how long it ran: a command that
    /// returned at once began after the resume was typed, and fails it,
    /// taking its deadline along.
    @Test func theStore_failsTheResume_fromTheCommandsExitAndDuration() {
        let store = StopLedgerStore(resumeTimeout: .seconds(30))
        _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let since = Self.start.addingTimeInterval(10)
        store.markResuming(id, window: nil, now: since)
        #expect(store.hasResumeClock)
        // A command that ran for 3 s and ended 1 s after the resume was
        // typed began before it: an earlier one.
        let earlier = store.resumeCommandFinished(
            inPane: Self.pane, exitCode: 0, durationNs: 3_000_000_000, now: since.addingTimeInterval(1)
        )
        #expect(earlier == nil)
        #expect(store.hasResumeClock)
        let quick = store.resumeCommandFinished(
            inPane: Self.pane, exitCode: 1, durationNs: 400_000_000, now: since.addingTimeInterval(1)
        )
        #expect(quick == .failed(id))
        #expect(store.ledger.record(id)?.resume == .failed)
        #expect(!store.hasResumeClock)
    }

    @Test func dismissingAStop_stopsItsResumeClock_andTheOffersSayWhoStartsNew() {
        let store = StopLedgerStore(resumeTimeout: .seconds(30))
        let run = Self.run("a", .error)
        let id = StopLedger.itemID(of: run)
        _ = store.update(runtimes: [run], paneExists: Self.always)
        store.refreshOffers { _ in (.available, nil) }
        #expect(store.startsNew == [id])
        store.refreshOffers { _ in (.available, .draft) }
        #expect(store.startsNew.isEmpty)
        #expect(store.newConversationBlockers == [id: .draft])
        store.refreshOffers { _ in (.available, nil) }
        #expect(store.offers[id] == .available)
        store.markResuming(id, window: nil)
        #expect(store.hasResumeClock)
        store.dismiss(id)
        #expect(!store.hasResumeClock)
        #expect(store.ledger.records.isEmpty)
        store.refreshOffers { _ in (.available, nil) }
        #expect(store.startsNew.isEmpty)
        #expect(store.newConversationBlockers.isEmpty)
    }

    @Test func aStopThatEnds_takesItsResumeClockAlong() {
        let store = StopLedgerStore(resumeTimeout: .milliseconds(50))
        _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        store.markResuming(id, window: nil)
        #expect(store.hasResumeClock)
        _ = store.update(runtimes: [Self.run("a", .running, episode: "2")], paneExists: Self.always)
        #expect(store.ledger.records.isEmpty)
        #expect(!store.hasResumeClock)
    }

    @Test func aResumeThatNeverComesBack_failsAfterItsTime() async {
        let store = StopLedgerStore(resumeTimeout: .milliseconds(50))
        _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        var toldOfTimeout = false
        store.onResumeTimedOut = { toldOfTimeout = true }
        store.markResuming(id, window: nil)
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(10)) { store.ledger.record(id)?.resume == .failed }
        #expect(store.ledger.record(id)?.resume == .failed)
        #expect(toldOfTimeout)
    }
}
