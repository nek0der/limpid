// TurnRetentionTests.swift
// Weir — what follows a deletion: the queue of turns on their way, and the sweep through the projection.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Turn retention", .timeLimit(.minutes(1)))
struct TurnRetentionTests {
    private typealias Fixture = TurnSummaryFixture
    private static let now = Date(timeIntervalSince1970: 1_791_763_200)
    private static let other = ConversationKey(provider: .codex, conversationID: "c2", isFallback: false)

    // MARK: - The deletion queue

    @Test func aBatch_reportsWhatWentWithItsConversation_andWhatStaysWaits() {
        var queue = TurnDeletionQueue()
        queue.isHistoryComplete = true
        queue.asked(["A", "B"]) { $0 == "A" ? Fixture.conversation : Self.other }
        queue.asked(["C"]) { _ in Self.other }
        #expect(!queue.mayAsk("A"), "on its way")

        let report = queue.finished(asked: ["A", "B"], [
            TurnDeletion(outcome: .deleted, turnID: "A", reason: nil, roots: nil),
            TurnDeletion(outcome: .failed, turnID: "B", reason: "refused", roots: nil)
        ], now: Self.now)

        #expect(report.gone == [TurnID("A"): Fixture.conversation])
        #expect(report.remaining == [Self.other], "B was not deleted, and C is still on its way")
        #expect(queue.mayAsk("A"))
        #expect(!queue.mayAsk("B"), "waits after the refusal")
        queue.forgetPastWaits(now: Self.now.addingTimeInterval(TurnDeletionQueue.retryDelay + 1))
        #expect(queue.mayAsk("B"))
    }

    @Test func batchesGoOneAtATime_andOneSweptWithLessProtectedIsSweptAgain() {
        let directory = URL(fileURLWithPath: "/turns")
        let swept = TurnProtection(protectedTurnIDs: [TurnID("u")], shownConversations: [])
        var queue = TurnDeletionQueue()
        for ids in [["a", "u"], ["b"], ["c"]] {
            queue.asked(ids) { _ in nil }
            queue.queue(ids, in: directory, sweptWith: swept)
        }

        // As protected as when it was swept: it goes whole, the unread turn
        // the count limits chose with it.
        let first = queue.nextBatch(protection: swept)
        #expect(first.batch?.turnIDs == ["a", "u"])
        #expect(!first.needsSweep)
        #expect(queue.nextBatch(protection: swept) == .init(), "one at a time")
        _ = queue.finished(asked: ["a", "u"], [], now: Date())

        // A review holds a turn now: the batch goes back to the sweep whole.
        let held = TurnProtection(
            protectedTurnIDs: [TurnID("u")], heldTurnIDs: [TurnID("x")], shownConversations: []
        )
        let second = queue.nextBatch(protection: held)
        #expect(second.batch == nil)
        #expect(second.needsSweep)
        #expect(queue.mayAsk("b") && queue.mayAsk("c"), "no longer on their way, and waiting for nothing")
        #expect(queue.waiting.isEmpty)

        // Nothing known about what protects turns: nothing goes, and no
        // sweep could choose anything.
        queue.asked(["d"]) { _ in nil }
        queue.queue(["d"], in: directory, sweptWith: swept)
        #expect(queue.nextBatch(protection: nil) == .init())
        #expect(queue.mayAsk("d"))
    }

    @Test func aBatch_reportsWhenTheTurnsGoneRan_byWorktree() {
        let early = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 60)
        let late = DateInterval(start: Date(timeIntervalSince1970: 2000), duration: 60)
        var queue = TurnDeletionQueue()
        queue.asked(["A", "B", "C"], spans: [
            "A": .init(root: "/repo", interval: late),
            "B": .init(root: "/repo", interval: early),
            "C": .init(root: "/other", interval: late)
        ]) { _ in nil }
        let report = queue.finished(asked: ["A", "B", "C"], [
            TurnDeletion(outcome: .deleted, turnID: "A", reason: nil, roots: nil),
            TurnDeletion(outcome: .alreadyGone, turnID: "B", reason: nil, roots: nil),
            TurnDeletion(outcome: .failed, turnID: "C", reason: "refused", roots: nil)
        ], now: Date())
        #expect(report.deletedIn == ["/repo": [late, early]], "a turn not deleted is not reported")
    }

    /// What the launch makes of the turns an earlier run had with the
    /// collector: one the launch's batch finished, and one whose deletion
    /// finished unheard, are gone with what they were; one put back is
    /// the next sweep's; one still aside waits for the next batch.
    @Test func theTurnsAnEarlierRunHadOnTheirWay_areSettledAtLaunch() throws {
        try withTempDir { root in
            let file = root.appendingPathComponent(TurnDeletionFile.fileName)
            let span = { (second: TimeInterval) in
                TurnDeletionQueue.Span(
                    root: "/repo",
                    interval: DateInterval(start: Date(timeIntervalSince1970: second), duration: 60)
                )
            }
            var earlier = TurnDeletionQueue(url: file)
            let ids = ["finished", "unheard", "putBack", "aside"]
            earlier.asked(ids, spans: Dictionary(uniqueKeysWithValues: ids.enumerated().map {
                ($0.element, span(TimeInterval(1000 * ($0.offset + 1))))
            })) { _ in Fixture.conversation }
            earlier.queue(ids, in: root, sweptWith: TurnProtection(protectedTurnIDs: [], shownConversations: []))
            _ = earlier.nextBatch(protection: TurnProtection(protectedTurnIDs: [], shownConversations: []))
            #expect(TurnDeletionFile.read(file).map(\.turnID) == ids.sorted())

            var queue = TurnDeletionQueue(url: file)
            queue.isHistoryComplete = true
            let report = queue.recovered(
                [TurnDeletion(outcome: .deleted, turnID: "finished", reason: nil, roots: nil)]
            ) { entry in
                switch entry.turnID {
                case "putBack": .present
                case "aside": .aside
                default: .gone
                }
            }

            #expect(report.gone == [TurnID("finished"): Fixture.conversation, TurnID("unheard"): Fixture.conversation])
            #expect(report.deletedIn["/repo"]?.map(\.start).sorted() == [span(1000), span(2000)].map(\.interval.start))
            #expect(
                TurnDeletionFile.read(file).map(\.turnID) == ["aside", "finished", "unheard"],
                "the spans stay until they are saved"
            )
            queue.spansSaved(report.spanTurnIDs)
            #expect(TurnDeletionFile.read(file).map(\.turnID) == ["aside"])
        }
    }

    /// The spans of a batch are saved a moment after it reports
    /// (`ViewedLineStore.noteDeletedTurns`): a quit in between must not
    /// lose them, as no record is left to say when the turn ran. The file
    /// keeps them, without the conversation the report already handed
    /// over, and the next launch reports them again.
    @Test func aBatchsSpans_stayInTheFileUntilSaved_andComeBackAfterAQuit() throws {
        try withTempDir { root in
            let file = root.appendingPathComponent(TurnDeletionFile.fileName)
            let span = TurnDeletionQueue.Span(
                root: "/repo",
                interval: DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 60)
            )
            let protection = TurnProtection(protectedTurnIDs: [], shownConversations: [])
            var queue = TurnDeletionQueue(url: file)
            queue.asked(["A", "B"], spans: ["A": span]) { _ in Fixture.conversation }
            queue.queue(["A", "B"], in: root, sweptWith: protection)
            _ = queue.nextBatch(protection: protection)
            let report = queue.finished(asked: ["A", "B"], [
                TurnDeletion(outcome: .deleted, turnID: "A", reason: nil, roots: nil),
                TurnDeletion(outcome: .deleted, turnID: "B", reason: nil, roots: nil)
            ], now: Self.now)
            #expect(report.spanTurnIDs == ["A"], "B has no span to keep")
            let kept = TurnDeletionFile.read(file)
            #expect(kept.map(\.turnID) == ["A"])
            #expect(kept.first?.span == span)
            #expect(kept.first?.conversation == nil, "the report handed it over")

            // After a quit before the spans are saved, the next launch finds
            // the record gone and reports the span again.
            var relaunched = TurnDeletionQueue(url: file)
            let again = relaunched.recovered([]) { _ in .gone }
            #expect(again.deletedIn == ["/repo": [span.interval]])
            #expect(again.gone == [TurnID("A"): ConversationKey?.none])
            #expect(TurnDeletionFile.read(file).map(\.turnID) == ["A"])
            relaunched.spansSaved(again.spanTurnIDs)
            #expect(!FileManager.default.fileExists(atPath: file.path), "nothing is left to keep")
        }
    }

    @Test func whileTheHistoryIsPartial_noConversationIsCalledEmpty() {
        var queue = TurnDeletionQueue()
        queue.asked(["A"]) { _ in Fixture.conversation }
        let report = queue.finished(
            asked: ["A"],
            [TurnDeletion(outcome: .deleted, turnID: "A", reason: nil, roots: nil)],
            now: Self.now
        )
        #expect(report.remaining == [Fixture.conversation])
    }

    // MARK: - Through the projection

    /// A stub collector: records each batch, holds it until released when
    /// told to, and answers as told. Set up front and read from the
    /// collector's queue; its closures are `@Sendable`, since written in
    /// this main-actor suite they would otherwise be the main actor's.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        private var recoveryCount = 0
        private let gate = DispatchSemaphore(value: 0)
        private let holds: Bool
        private let holdsRecovery: Bool
        private let answer: @Sendable ([String]) throws -> [TurnDeletion]

        init(
            holds: Bool = false,
            holdsRecovery: Bool = false,
            answer: @escaping @Sendable ([String]) throws -> [TurnDeletion] = { ids in
                ids.map { TurnDeletion(outcome: .deleted, turnID: $0, reason: nil, roots: nil) }
            }
        ) {
            self.holds = holds
            self.holdsRecovery = holdsRecovery
            self.answer = answer
        }

        /// The batches that named turns; the one each launch sends to
        /// finish what a quit cut short is counted apart (`recoveries`).
        var batches: [[String]] {
            lock.withLock { recorded }
        }

        var recoveries: Int {
            lock.withLock { recoveryCount }
        }

        /// Only the first batch is held: a second, asked for by mistake,
        /// must reach `batches` rather than wait behind the gate.
        func apply(_ ids: [String]) throws -> [TurnDeletion] {
            if ids.isEmpty {
                lock.withLock { recoveryCount += 1 }
                if holdsRecovery {
                    gate.wait()
                }
                return try answer(ids)
            }
            let isFirst = lock.withLock {
                recorded.append(ids)
                return recorded.count == 1
            }
            if holds, isFirst {
                gate.wait()
            }
            return try answer(ids)
        }

        func release() {
            gate.signal()
        }
    }

    private struct Scene {
        let adapter: AgentProjectionAdapter
        /// Held here: the adapter keeps its session weakly, and a pass
        /// without one does not run.
        let session: WorkspaceSession
        let state: URL
        let old: String
        let unread: String

        func recordURL(_ id: String) throws -> URL {
            try AgentRecordFixtures.turns(in: state).appendingPathComponent(id + AgentRecordFixtures.layout().turnRecordSuffix)
        }
    }

    /// Two turns of conversation `s1` past the age limit in one worktree,
    /// the later one protected as unread once the host says what it
    /// protects.
    private func scene(in root: URL, collector: Collector, turnDeletionsURL: URL? = nil) throws -> Scene {
        let state = root.appendingPathComponent("states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let old = UUID().uuidString
        let unread = UUID().uuidString
        for (id, number, startedAt) in [(old, 1, "2026-08-30T00:00:00Z"), (unread, 2, "2026-09-01T00:00:00Z")] {
            try AgentRecordFixtures.writeTurn(
                id: id, number: number, session: "s1", runID: "RUN", startedAt: startedAt, in: state
            )
        }
        let adapter = makeAdapter(state: state, sessions: sessions, collector: collector, turnDeletionsURL: turnDeletionsURL)
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        adapter.bootstrap(into: session, attention: AttentionState())
        adapter.refresh()
        adapter.turnProtection = { TurnProtection(protectedTurnIDs: [TurnID(unread)], shownConversations: []) }
        return Scene(adapter: adapter, session: session, state: state, old: old, unread: unread)
    }

    private func makeAdapter(
        state: URL,
        sessions: URL,
        collector: Collector,
        turnDeletionsURL: URL? = nil
    ) -> AgentProjectionAdapter {
        ProjectionFixture.adapter(
            provider: "claude",
            state: state,
            sessions: sessions,
            resumeIntents: AgentResumeIntentStore(directory: state.appendingPathComponent("intents")),
            turnDeletionsURL: turnDeletionsURL,
            processStatus: { _ in .dead },
            turnCollector: TurnGarbageCollector(priority: .userInitiated) { ids, _ in try collector.apply(ids) }
        )
    }

    /// The count is the sweep's own (`turn_retention.rs` tests the rule);
    /// this sees it reach Advanced through the bridge, and delete nothing.
    @Test func whatALimitDeletes_isCountedByTheSweep_withoutDeleting() async throws {
        try await withTempDir { root in
            let collector = Collector()
            let scene = try scene(in: root, collector: collector)
            let keepsAll = TurnRetentionLimits(maxAgeSeconds: .max, maxPerConversation: 500)

            // Both turns are past 14 days; the unread one is spared the age.
            #expect(await scene.adapter.turnsTaken(from: keepsAll, to: .standard) == 1)
            #expect(await scene.adapter.turnsTaken(from: .standard, to: .standard) == 0)
            scene.adapter.turnProtection = { nil }
            #expect(await scene.adapter.turnsTaken(from: keepsAll, to: .standard) == 0, "nothing goes before turns are judged")
            #expect(collector.batches.isEmpty)
        }
    }

    @Test func aTurnPastTheLimits_isDeleted_andItsConversationIsReported() async throws {
        try await withTempDir { root in
            let collector = Collector()
            let scene = try scene(in: root, collector: collector)
            var forgotten: [TurnID: ConversationKey?] = [:]
            var stillThere: Set<ConversationKey> = []
            scene.adapter.onTurnsDeleted = { gone, remaining in
                forgotten.merge(gone) { _, new in new }
                stillThere = remaining
            }
            var deletedIn: [String: [DateInterval]] = [:]
            scene.adapter.onTurnsDeletedIn = { spans in
                deletedIn = spans
                return true
            }

            scene.adapter.refresh()
            await pollUntilTurnsDeleted { !forgotten.isEmpty && !deletedIn.isEmpty }

            // The turn that went, from when it started.
            #expect(deletedIn.keys.sorted() == ["/r"], "the worktree its snapshots were taken in")
            #expect(deletedIn.values.flatMap(\.self).count == 1)
            #expect(deletedIn.values.first?.first?.start == UnreadTurnRules.date("2026-08-30T00:00:00Z"))
            #expect(scene.adapter.lastFailure == nil)
            #expect(collector.batches == [[scene.old]], "the unread turn stays")
            let reported = try #require(forgotten[TurnID(scene.old)])
            #expect(reported?.conversationID == "s1")
            #expect(stillThere.isEmpty)
        }
    }

    @Test func aTurnOnItsWay_isNotAskedForAgain_andItsConversationOutlivesAPassThatDropsIt() async throws {
        try await withTempDir { root in
            let collector = Collector(holds: true)
            let scene = try scene(in: root, collector: collector)
            var forgotten: [TurnID: ConversationKey?] = [:]
            scene.adapter.onTurnsDeleted = { gone, _ in forgotten.merge(gone) { _, new in new } }

            scene.adapter.refresh()
            await pollUntilTurnsDeleted { collector.batches.count == 1 }
            // The record is still there, so the rules choose the turn again:
            // only its being on its way keeps it from a second batch.
            scene.adapter.refresh()
            scene.adapter.refresh()
            #expect(collector.batches.count == 1)

            // As the bridge does: the record leaves the directory, and a pass
            // reads it gone before the batch reports.
            try FileManager.default.removeItem(at: scene.recordURL(scene.old))
            scene.adapter.refresh()
            collector.release()
            await pollUntilTurnsDeleted { !forgotten.isEmpty }
            // A second batch, asked for while the first was held, would be
            // sent as the first reports, which has happened by now.
            #expect(!scene.adapter.turnDeletions.isSending)
            #expect(scene.adapter.turnDeletions.waiting.isEmpty)

            #expect(collector.batches.count == 1)
            #expect(forgotten[TurnID(scene.old)]??.conversationID == "s1", "remembered from when it was asked for")
        }
    }

    @Test(arguments: ["failed", "unreadable", "thrown"])
    func aTurnNotDeleted_waitsBeforeItIsAskedForAgain(_ how: String) async throws {
        try await withTempDir { root in
            let collector = Collector { ids in
                switch how {
                case "failed": return ids.map { TurnDeletion(outcome: .failed, turnID: $0, reason: "refused", roots: nil) }
                case "unreadable": return ids.map { TurnDeletion(outcome: .unreadable, turnID: $0, reason: nil, roots: nil) }
                default: throw CancellationError()
                }
            }
            let scene = try scene(in: root, collector: collector)
            var clock = Self.now
            scene.adapter.turnDeletionClock = { clock }

            scene.adapter.refresh()
            // Reported back: the turn is waiting, no longer on its way.
            await pollUntilTurnsDeleted { scene.adapter.turnDeletions.retryAfter[scene.old] != nil }
            scene.adapter.refresh()
            // A batch is sent from the pass that asks for it.
            #expect(!scene.adapter.turnDeletions.isSending && scene.adapter.turnDeletions.waiting.isEmpty, "within the wait")
            #expect(collector.batches.count == 1)

            clock = clock.addingTimeInterval(11 * 60)
            scene.adapter.refresh()
            await pollUntilTurnsDeleted { collector.batches.count == 2 }
            #expect(collector.batches.count == 2, "asked again once the wait is over")
        }
    }

    @Test func noTurnIsDeleted_untilEveryRecordHasArrived() async throws {
        try await withTempDir { root in
            let collector = Collector()
            let scene = try scene(in: root, collector: collector)
            // Two new records, one a pass: the first pass leaves one unread.
            for number in [3, 4] {
                try AgentRecordFixtures.writeTurn(
                    id: UUID().uuidString, number: number, session: "s1", runID: "RUN",
                    startedAt: "2026-09-05T00:00:00Z", in: scene.state
                )
            }
            scene.adapter.turnContentBudgetBytes = 1

            scene.adapter.refresh()
            // Asked for synchronously in a pass, so none was asked for here.
            #expect(scene.adapter.turnDeletions.inFlight.isEmpty, "the record not read yet could be the unread one")
            // The adapter runs the rest at once, and then sweeps.
            await pollUntilTurnsDeleted { !collector.batches.isEmpty }
            #expect(collector.batches.first?.contains(scene.old) == true)
        }
    }

    @Test func aTurnOpenedInAReviewWhileItsBatchWaits_isNotDeleted() async throws {
        try await withTempDir { root in
            let collector = Collector(holds: true)
            let scene = try scene(in: root, collector: collector)
            var forgotten: [TurnID: ConversationKey?] = [:]
            scene.adapter.onTurnsDeleted = { gone, _ in forgotten.merge(gone) { _, new in new } }

            scene.adapter.refresh()
            await pollUntilTurnsDeleted { collector.batches.count == 1 }
            // The second turn is no longer protected: a pass asks for it,
            // and its batch waits behind the first.
            scene.adapter.turnProtection = { TurnProtection(protectedTurnIDs: [], shownConversations: []) }
            scene.adapter.refresh()
            #expect(scene.adapter.turnDeletions.waiting.map(\.turnIDs) == [[scene.unread]])
            // A review opens its range before the first batch finishes.
            scene.adapter.turnProtection = {
                TurnProtection(protectedTurnIDs: [], heldTurnIDs: [TurnID(scene.unread)], shownConversations: [])
            }
            // As the bridge does: the record leaves before the batch reports.
            try FileManager.default.removeItem(at: scene.recordURL(scene.old))
            collector.release()
            await pollUntilTurnsDeleted { !forgotten.isEmpty }
            // The sweep runs again with the review's range held.
            await scene.adapter.passesSettled()
            #expect(!scene.adapter.turnDeletions.isSending, "no batch was sent for the held turn")

            #expect(collector.batches == [[scene.old]])
            #expect(try FileManager.default.fileExists(atPath: scene.recordURL(scene.unread).path))
            #expect(scene.adapter.turnDeletions.mayAsk(scene.unread))

            // The review closes: the sweep that comes next chooses it again.
            scene.adapter.turnProtection = { TurnProtection(protectedTurnIDs: [], shownConversations: []) }
            scene.adapter.requestPass()
            await scene.adapter.passesSettled()
            await pollUntilTurnsDeleted { collector.batches.count == 2 }
            #expect(collector.batches.last == [scene.unread])
        }
    }

    @Test func aDeletionAQuitCutShort_isFinishedAtLaunch_andItsTurnForgotten() async throws {
        try await withTempDir { root in
            let recovered = UUID().uuidString
            // Held, so what it reports is heard after the test listens.
            let collector = Collector(holdsRecovery: true) { ids in
                ids.isEmpty
                    ? [TurnDeletion(outcome: .deleted, turnID: recovered, reason: nil, roots: nil)]
                    : ids.map { TurnDeletion(outcome: .deleted, turnID: $0, reason: nil, roots: nil) }
            }
            // No protection yet at launch: the sweep asks for nothing, and
            // the only batch is the one that finishes what was cut short.
            let scene = try scene(in: root, collector: collector)
            var forgotten: [TurnID: ConversationKey?] = [:]
            scene.adapter.onTurnsDeleted = { gone, _ in forgotten.merge(gone) { _, new in new } }
            await pollUntilTurnsDeleted { collector.recoveries == 1 }
            #expect(collector.recoveries == 1, "sent at launch")
            #expect(collector.batches.isEmpty)

            collector.release()
            await pollUntilTurnsDeleted { !forgotten.isEmpty }
            #expect(forgotten.keys.contains(TurnID(recovered)))
        }
    }

    /// A quit cuts off a batch after its record moved aside: the next
    /// launch finishes it before any pass has read the records, and still
    /// reports when it ran and its conversation, from the file the first
    /// run kept. Without them, what the turn changed would count as
    /// changed outside turns once a gap opened there.
    @Test func aDeletionAQuitCutOff_isReportedAtTheNextLaunch_withWhenItRan() async throws {
        try await withTempDir { root in
            let file = root.appendingPathComponent(TurnDeletionFile.fileName)
            let first = Collector(holds: true)
            let scene = try scene(in: root, collector: first, turnDeletionsURL: file)
            scene.adapter.refresh()
            await pollUntilTurnsDeleted { first.batches.count == 1 }
            #expect(TurnDeletionFile.read(file).map(\.turnID) == [scene.old], "kept before the batch goes")
            // As the bridge leaves it when the quit comes: moved aside.
            let record = try scene.recordURL(scene.old)
            try FileManager.default.moveItem(
                at: record,
                to: record.deletingLastPathComponent().appendingPathComponent(".\(record.lastPathComponent).deleting")
            )

            let old = scene.old
            let second = Collector { ids in
                ids.isEmpty ? [TurnDeletion(outcome: .deleted, turnID: old, reason: nil, roots: nil)] : []
            }
            let relaunched = makeAdapter(
                state: scene.state,
                sessions: root.appendingPathComponent("sessions", isDirectory: true),
                collector: second,
                turnDeletionsURL: file
            )
            var forgotten: [TurnID: ConversationKey?] = [:]
            var deletedIn: [String: [DateInterval]] = [:]
            relaunched.onTurnsDeleted = { gone, _ in forgotten.merge(gone) { _, new in new } }
            relaunched.onTurnsDeletedIn = { spans in
                deletedIn = spans
                return true
            }
            relaunched.bootstrap(into: scene.session, attention: AttentionState())
            await pollUntilTurnsDeleted { !deletedIn.isEmpty }

            #expect(deletedIn["/r"]?.map(\.start) == UnreadTurnRules.date("2026-08-30T00:00:00Z").map { [$0] })
            #expect(forgotten[TurnID(old)]??.conversationID == "s1")
            await pollUntilTurnsDeleted { !FileManager.default.fileExists(atPath: file.path) }
            #expect(!FileManager.default.fileExists(atPath: file.path), "nothing is on its way, and the span is saved")
            first.release()
        }
    }

    @Test func beforeTheHostSaysWhatItProtects_noTurnIsDeleted() throws {
        try withTempDir { root in
            let collector = Collector()
            let scene = try scene(in: root, collector: collector)
            scene.adapter.turnProtection = { nil }

            scene.adapter.refresh()
            scene.adapter.refresh()

            // A batch is sent from the pass that asks for it.
            #expect(!scene.adapter.turnDeletions.isSending && scene.adapter.turnDeletions.waiting.isEmpty)
            #expect(collector.batches.isEmpty)
        }
    }
}
