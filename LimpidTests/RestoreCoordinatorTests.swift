// RestoreCoordinatorTests.swift
// Limpid — restores and their undo through the Rust bridge against a real repository, and the journals the app keeps.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct RestoreCoordinatorTests {
    /// A repository whose `a.txt` and `b.txt` changed after a turn began, and the turn,
    /// recorded the way the hook records one.
    private struct Scene {
        let repo: TempGitRepo
        let root: String
        let states: URL
        let turn: TurnSummary
        let coordinator: RestoreCoordinator

        var file: URL {
            URL(fileURLWithPath: root).appendingPathComponent("a.txt")
        }

        func contents() throws -> String {
            try String(contentsOf: file, encoding: .utf8)
        }

        func cleanup() {
            repo.cleanup()
        }
    }

    /// The scene, with the agent's state directory at `states`.
    private static func scene(states: URL) async throws -> Scene {
        let repo = try await TempGitRepo.make()
        try "a\n".write(to: repo.url.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: repo.url.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await repo.git(["add", "a.txt", "b.txt"])
        try await repo.git(["commit", "-q", "-m", "a"])
        let root = try await repo.git(["rev-parse", "--show-toplevel"])
        let tree = try await repo.git(["rev-parse", "HEAD^{tree}"])
        let head = try await repo.git(["rev-parse", "HEAD"])
        let turns = states.appendingPathComponent("turns")
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        let turnID = UUID().uuidString.uppercased()
        let record = """
        {"schemaVersion":1,"turnId":"\(turnID)","provider":"claude",
         "conversation":{"provider":"claude","conversationId":"s1","isFallback":false},
         "runId":"R","paneId":"P","displayNumber":7,"startedAt":"2026-10-13T00:00:00Z","phase":"finished",
         "gitContext":{"head":"\(head)","branch":"main","root":"\(root)"},
         "begin":{"kind":"captured","tree":"\(tree)","root":"\(root)"},"end":{"kind":"pending"},
         "changes":{"kind":"unchanged"}}
        """
        try record.write(to: turns.appendingPathComponent("\(turnID).turn.json"), atomically: true, encoding: .utf8)
        for name in ["a", "b"] {
            let file = URL(fileURLWithPath: root).appendingPathComponent("\(name).txt")
            try "\(name)\nchanged\n".write(to: file, atomically: true, encoding: .utf8)
        }
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: tree, root: root)
        let turn = try TurnSummaryFixture.turn(turnID, number: 7, extras: extras)
        let coordinator = RestoreCoordinator(stateDirectories: [RestoreStateDirectory(provider: .claude, directory: states)])
        return Scene(repo: repo, root: root, states: states, turn: turn, coordinator: coordinator)
    }

    private static func journal(_ outcome: RestoreOutcome?) throws -> RestoreJournal {
        guard case let .finished(journal) = outcome else { throw CocoaError(.coderInvalidValue) }
        return journal
    }

    /// A restore is refused while an agent of the worktree runs, which the
    /// coordinator reads from the state directories it is given; once none
    /// does, the restore and its undo move the working tree and the records.
    @Test(.tags(.smoke, .slow)) func restore_isRefusedWhileAnAgentRuns_thenItAndItsUndoMoveTheTreeAndTheRecords() async throws {
        try await withTempDir { states in
            let scene = try await Self.scene(states: states)
            defer { scene.cleanup() }
            let coordinator = scene.coordinator
            let running = scene.states.appendingPathComponent("R2.state.json")
            try """
            {"schemaVersion":3,"paneId":"P2","runId":"R2","revision":1,"state":"running",
             "updatedAt":"2026-10-13T00:00:00Z","turnRoot":"\(scene.root)"}
            """.write(to: running, atomically: true, encoding: .utf8)

            #expect(await coordinator.restore(scene.turn) == .refused(.agentActive(.claude)))
            #expect(try scene.contents() == "a\nchanged\n")
            #expect(coordinator.latestUndoable(in: scene.root) == nil)
            try FileManager.default.removeItem(at: running)

            let restored = try await Self.journal(coordinator.restore(scene.turn))
            #expect(restored.stage == .applied)
            #expect(try scene.contents() == "a\n")
            #expect(coordinator.latestUndoable(in: scene.root) == restored)
            #expect(restored.turnNumber == 7, "the record names the turn by its own copy of the number")
            #expect(!coordinator.isBusy(scene.root))

            let undo = try await Self.journal(coordinator.undo(restored))
            #expect(undo.stage == .applied)
            #expect(undo.undoes == restored.opID)
            #expect(try scene.contents() == "a\nchanged\n")
            #expect(coordinator.latestUndoable(in: scene.root) == nil)
            #expect(coordinator.journals[scene.root]?.first { $0.opID == restored.opID }?.stage == .undone(by: undo.opID))
        }
    }

    /// A restore a quit cut short is told of when the journals are read at
    /// launch, once, and is kept as the worktree's undoable restore. How the
    /// bridge classifies the journal is its own tests' subject
    /// (`recover_classifies_interrupted_journal`).
    @Test(.tags(.smoke, .slow)) func recover_settlesARestoreCutShort() async throws {
        try await withTempDir { states in
            let scene = try await Self.scene(states: states)
            defer { scene.cleanup() }
            let restored = try await Self.journal(scene.coordinator.restore(scene.turn))
            // As a quit leaves it: still writing.
            let file = URL(fileURLWithPath: scene.root).appendingPathComponent(".git/limpid/restores/\(restored.opID).json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["stage"] = ["kind": "writing", "done": [String]()]
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            // One path written, the other not yet: the restore stopped partway.
            let other = URL(fileURLWithPath: scene.root).appendingPathComponent("b.txt")
            try "b\nchanged\n".write(to: other, atomically: true, encoding: .utf8)

            let coordinator = RestoreCoordinator(stateDirectories: [])
            let report = await coordinator.recover(roots: [scene.repo.url.path])

            #expect(report.interrupted.map(\.opID) == [restored.opID])
            #expect(report.unsettledRoots.isEmpty)
            #expect(coordinator.latestUndoable(in: scene.root)?.opID == restored.opID)
            // Told once: the next reading finds it settled already.
            let again = await coordinator.recover(roots: [scene.repo.url.path])
            #expect(again.interrupted.isEmpty)
        }
    }

    /// Journals that are there but cannot be read are no empty list, from
    /// Rust through the bridge to the coordinator: the reading says it is
    /// incomplete, the restore known stays undoable, the worktree stays
    /// marked, and it is read again, as one a hook kept locked is.
    @Test(.tags(.slow)) func journalsThatCannotBeRead_areAnIncompleteReading_notNone() async throws {
        try await withTempDir { states in
            let scene = try await Self.scene(states: states)
            defer { scene.cleanup() }
            let restored = try await Self.journal(scene.coordinator.restore(scene.turn))
            let journals = URL(fileURLWithPath: scene.root).appendingPathComponent(".git/limpid/restores")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journals.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journals.path) }

            let reading = try LimpidRestoreBridge.recover(root: scene.root)
            #expect(reading == RestoreRecovery(journals: [], settled: [], isIncomplete: true))
            let report = await scene.coordinator.recover(roots: [scene.root])

            #expect(report.unsettledRoots == [scene.root])
            #expect(scene.coordinator.incompleteRoots == [scene.root])
            #expect(scene.coordinator.latestUndoable(in: scene.root)?.opID == restored.opID)
        }
    }

    /// An incomplete reading at launch is taken in for what it read: the
    /// discard it settled is told with Undo and the restore it read is
    /// offered, while the worktree stays marked and is read again. A later
    /// incomplete reading that leaves the restore out does not drop it; a
    /// whole one stands for every journal there is, and clears the mark.
    @Test func anIncompleteReading_takesInWhatItRead_andKeepsTheRest() async throws {
        let restore = try Self.decodedJournal(root: "/repo", opID: "R")
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", stage: Self.cutShort, operation: "discard")
        let readings = Recorded([
            RestoreRecovery(journals: [restore, discard], settled: ["D"], isIncomplete: true),
            RestoreRecovery(journals: [discard], settled: [], isIncomplete: true),
            RestoreRecovery(journals: [discard], settled: [], isIncomplete: false)
        ])
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in
                var next: RestoreRecovery?
                readings.update { next = $0.isEmpty ? nil : $0.removeFirst() }
                guard let next else { throw LimpidRestoreBridgeError.rust(-1) }
                return next
            }
        ))
        // Only the whole reading is heard: what a restore keeps while it can
        // be undone must not go for a journal a reading could not read.
        let heard = Recorded<[[String]]>([])
        coordinator.onWholeReading = { root, journals in
            heard.update { $0.append([root] + journals.map(\.opID)) }
        }

        let first = await coordinator.recover(roots: ["/repo"])
        #expect(first.interrupted.map(\.opID) == ["D"])
        #expect(first.unsettledRoots == ["/repo"])
        #expect(coordinator.incompleteRoots == ["/repo"])
        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "R")

        let second = await coordinator.recover(roots: ["/repo"])
        #expect(second.interrupted.isEmpty)
        #expect(second.unsettledRoots == ["/repo"])
        #expect(coordinator.journals["/repo"]?.map(\.opID).sorted() == ["D", "R"])
        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "R")

        let whole = await coordinator.recover(roots: ["/repo"])
        #expect(whole.unsettledRoots.isEmpty)
        #expect(coordinator.incompleteRoots.isEmpty)
        #expect(coordinator.journals["/repo"]?.map(\.opID) == ["D"])
        #expect(coordinator.latestUndoable(in: "/repo") == nil)
        #expect(heard.value == [["/repo", "D"]])
    }

    /// One operation at a time in a worktree: a second restore, or an undo,
    /// while one runs is not started. The second calls run as tasks the test
    /// polls, and only the first bridge call blocks: were the guard gone, they
    /// would queue on the runner behind the first, and an awaited call would
    /// never reach the line that releases it.
    @Test(.timeLimit(.minutes(1))) func anOperationUnderWay_keepsAnotherFromStarting() async throws {
        let release = DispatchSemaphore(value: 0)
        let calls = Recorded(0)
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in
                calls.update { $0 += 1 }
                if calls.value == 1 {
                    release.wait()
                }
                return .refused(.agentRecording)
            },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [], settled: []) }
        ))
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("a", 1), root: "/repo")
        let turn = try TurnSummaryFixture.turn("T1", extras: extras)
        let journal = try Self.decodedJournal(root: "/repo")

        let first = Task { await coordinator.restore(turn) }
        await pollUntil(timeout: .seconds(5)) { coordinator.isBusy("/repo") }
        #expect(coordinator.isBusy("/repo"))
        let second = Recorded<[RestoreOutcome?]?>(nil)
        Task {
            let restored = await coordinator.restore(turn)
            let undone = await coordinator.undo(journal)
            second.value = [restored, undone]
        }
        await pollUntil(timeout: .seconds(5)) { second.value != nil }
        #expect(second.value == [nil, nil])
        release.signal()

        #expect(await first.value == .refused(.agentRecording))
        #expect(!coordinator.isBusy("/repo"))
        #expect(calls.value == 1)
    }

    /// The record says how the last undo fell short until the next
    /// operation in the worktree.
    @Test func anUndoThatFellShort_isKept_untilTheNextOperation() async throws {
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.mergeInProgress) },
            undo: { _, _, _ in .refused(.changedSinceRestore(paths: ["a.txt"])) },
            recover: { _ in RestoreRecovery(journals: [], settled: []) }
        ))
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("a", 1), root: "/repo")
        let turn = try TurnSummaryFixture.turn("T1", extras: extras)

        let journal = try Self.decodedJournal(root: "/repo")
        _ = await coordinator.undo(journal)
        #expect(coordinator.undoResults["/repo"] == .refused(.changedSinceRestore(paths: ["a.txt"])))

        _ = await coordinator.restore(turn)
        #expect(coordinator.undoResults["/repo"] == nil)
    }

    /// A discard is no restore: it has no record, and how its undo fell
    /// short is its hunk's to say, not the record's.
    @Test func aDiscard_isLeftOutOfTheRestoreRecord_andItsUndoResult() async throws {
        let restore = try Self.decodedJournal(root: "/repo", opID: "R")
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", operation: "discard")
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.changedSinceRestore(paths: ["a.txt"])) },
            recover: { _ in RestoreRecovery(journals: [restore, discard], settled: []) }
        ))
        _ = await coordinator.recover(roots: ["/repo"])

        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "R")
        _ = await coordinator.undo(discard)
        #expect(coordinator.undoResults["/repo"] == nil)
        _ = await coordinator.undo(restore)
        #expect(coordinator.undoResults["/repo"] == .refused(.changedSinceRestore(paths: ["a.txt"])))
    }

    /// A discard a crash cut short is told at launch, as a restore is: no
    /// review offers its undo once the app has quit.
    @Test func aDiscardCutShort_isToldAtLaunch() async throws {
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", stage: Self.cutShort, operation: "discard")
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [discard], settled: ["D"]) }
        ))

        let report = await coordinator.recover(roots: ["/repo"])

        #expect(report.interrupted.map(\.operation) == [.discard])
    }

    /// A discard that ended as the app quit is told too, with the saves
    /// recovery kept aside: its review, and the hunk's undo, went with the
    /// app. A restore that ended so has its record, and is not.
    @Test func aDiscardEndedAtQuit_isToldAtLaunch_withTheSavesKeptAside() async throws {
        let whole = #"{"kind":"partiallyApplied","reason":"keptAside","currentTree":"c","#
            + #""failed":[{"path":"f.txt","reason":"keptAside:.limpid-D/target/ready-1/f.txt"}]}"#
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", stage: whole, operation: "discard")
        let restore = try Self.decodedJournal(root: "/repo", opID: "R", stage: #"{"kind":"applied"}"#, operation: "restore")
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [restore, discard], settled: ["R", "D"]) }
        ))

        let report = await coordinator.recover(roots: ["/repo"])

        #expect(report.interrupted.map(\.opID) == ["D"])
        #expect(report.keptAside == [RestoreKeptAside(path: "f.txt", location: ".limpid-D/target/ready-1/f.txt")])
        #expect(RecoveryNews.kind(report.stops) == .discardSettled)
    }

    /// An undo cut short is told as an undo, though its Undo takes back
    /// the operation it was undoing; several are told by their count.
    @Test func eachStopAtLaunch_isToldAsWhatItWas() async throws {
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", stage: #"{"kind":"applied"}"#, operation: "discard")
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "D", stage: Self.cutShort, operation: "discard")
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [discard, undo], settled: ["U"]) }
        ))

        let report = await coordinator.recover(roots: ["/repo"])

        #expect(report.interrupted.map(\.opID) == ["D"])
        #expect(RecoveryNews.kind(report.stops) == .undoInterrupted)
        #expect(RecoveryNews.kind(report.stops + report.stops) == .operationsInterrupted(count: 2))
        #expect(RecoveryNews.kind([]) == nil)
        // A later reading of the same launch adds to the first, once.
        let merged = report.adding(report)
        #expect(merged.stops == report.stops)
    }

    /// Polled the same way as the restore above, so a broken guard fails the
    /// test instead of holding it on the runner.
    @Test(.timeLimit(.minutes(1))) func aDiscard_waitsForNoOtherOperation() async throws {
        let release = DispatchSemaphore(value: 0)
        let calls = Recorded(0)
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in
                calls.update { $0 += 1 }
                if calls.value == 1 {
                    release.wait()
                }
                return .refused(.agentRecording)
            },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [], settled: []) },
            discard: { _, _ in .finished(nil, []) }
        ))
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("a", 1), root: "/repo")
        let turn = try TurnSummaryFixture.turn("T1", extras: extras)
        let range = try JSONDecoder().decode(ReviewTurnRange.self, from: Data("""
        {"conversation":{"provider":"claude","conversationId":"s1","isFallback":false},"firstTurnID":"T1","restTurnIDs":[],
         "firstNumber":1,"lastNumber":1,"beginTree":"\(TurnSummaryFixture.tree("a", 1))",
         "endTree":"\(TurnSummaryFixture.tree("b", 1))","root":"/repo"}
        """.utf8))
        let call = RestoreCoordinator.DiscardCall(range: range, lastTurnNumber: 1, paneID: "P", files: [])

        let first = Task { await coordinator.restore(turn) }
        await pollUntil(timeout: .seconds(5)) { coordinator.isBusy("/repo") }
        let refused = Recorded<DiscardOutcome??>(nil)
        Task { refused.value = await coordinator.discard(call) }
        await pollUntil(timeout: .seconds(5)) { refused.value != nil }
        #expect(refused.value == .some(nil))
        release.signal()
        _ = await first.value
        #expect(await coordinator.discard(call) == .finished(nil, []))
    }

    private static func decodedJournal(
        root: String,
        opID: String = "OP",
        undoes: String? = nil,
        stage: String = #"{"kind":"applied"}"#,
        operation: String? = nil
    ) throws -> RestoreJournal {
        try RestoreJournalFixture.make(
            stageJSON: stage,
            fields: .init(opID: opID, operation: operation, root: root, turnID: "T1", undoes: undoes, at: "2026-10-13T00:00:00Z")
        )
    }

    private static let cutShort = #"{"kind":"partiallyApplied","reason":"interrupted","currentTree":"c"}"#

    /// An undo cut short offers its restore, which still has what the undo
    /// did not take back; an undo is not undone in turn.
    @Test func anUndoCutShort_offersItsRestore() async throws {
        let restore = try Self.decodedJournal(root: "/repo", opID: "R")
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "R", stage: Self.cutShort)
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [restore, undo], settled: ["U"]) }
        ))

        let report = await coordinator.recover(roots: ["/repo"])

        #expect(report.interrupted.map(\.opID) == ["R"])
    }

    /// A coordinator whose readings are `readings`, one per call, and that
    /// keeps its pending notices at `pending`.
    private static func readingInTurn(
        _ readings: Recorded<[RestoreRecovery]>,
        pending: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) -> RestoreCoordinator {
        RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in
                var next: RestoreRecovery?
                readings.update { next = $0.isEmpty ? nil : $0.removeFirst() }
                guard let next else { throw LimpidRestoreBridgeError.rust(-1) }
                return next
            }
        ), pendingStopsURL: pending, now: now)
    }

    /// An undo cut short whose discard could not be read when recovery
    /// settled it is told once, when a later reading lists the discard:
    /// Rust names the undo as settled only the first time.
    @Test func anUndoCutShort_whoseOperationIsReadLater_isToldOnce() async throws {
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", operation: "discard")
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "D", stage: Self.cutShort, operation: "discard")
        let readings = Recorded([
            RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
            RestoreRecovery(journals: [undo], settled: [], isIncomplete: true),
            RestoreRecovery(journals: [discard, undo], settled: [], isIncomplete: false),
            RestoreRecovery(journals: [discard, undo], settled: [], isIncomplete: false),
            RestoreRecovery(journals: [], settled: [], isIncomplete: false)
        ])
        let coordinator = Self.readingInTurn(readings)

        let first = await coordinator.recover(roots: ["/repo"])
        #expect(first.stops.isEmpty)
        #expect(first.unsettledRoots == ["/repo"])
        #expect(coordinator.pendingStopRoots == ["/repo"])
        // Still incomplete: it keeps waiting.
        #expect(await coordinator.recover(roots: ["/repo"]).stops.isEmpty)

        let whole = await coordinator.recover(roots: ["/repo"])
        #expect(whole.stops == [RestoreCoordinator.RecoveredStop(settled: undo, undoable: discard)])
        #expect(RecoveryNews.kind(whole.stops) == .undoInterrupted)
        #expect(coordinator.pendingStopRoots.isEmpty)
        #expect(await coordinator.recover(roots: ["/repo"]).stops.isEmpty)
        #expect(await coordinator.recover(roots: ["/repo"]).stops.isEmpty)
    }

    /// The same, when the reading that settles the undo lists its discard:
    /// told at once, and once.
    @Test func anUndoCutShort_whoseOperationIsRead_isToldOnceAtOnce() async throws {
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", operation: "discard")
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "D", stage: Self.cutShort, operation: "discard")
        let coordinator = Self.readingInTurn(Recorded([
            RestoreRecovery(journals: [discard, undo], settled: ["U"], isIncomplete: false),
            RestoreRecovery(journals: [], settled: [], isIncomplete: false)
        ]))

        let report = await coordinator.recover(roots: ["/repo"])
        #expect(report.stops == [RestoreCoordinator.RecoveredStop(settled: undo, undoable: discard)])
        #expect(coordinator.pendingStopRoots.isEmpty)
        #expect(await coordinator.recover(roots: ["/repo"]).stops.isEmpty)
    }

    /// A worktree asked by another spelling than its journals' root: its
    /// notice waits under the journals' root, an empty reading by the other
    /// spelling cannot say the operation is gone, and the launch reads the
    /// journals' root too.
    @Test func aPendingNotice_waitsUnderItsJournalsRoot() async throws {
        let restore = try Self.decodedJournal(root: "/repo", opID: "R")
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "R", stage: Self.cutShort)
        let coordinator = Self.readingInTurn(Recorded([
            RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
            RestoreRecovery(journals: [], settled: [], isIncomplete: false),
            RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false),
            RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false)
        ]))

        #expect(await coordinator.recover(roots: ["/link/repo"]).stops.isEmpty)
        #expect(coordinator.pendingStopRoots == ["/repo"])
        #expect(await coordinator.recover(roots: ["/link/repo"]).stops.isEmpty)
        #expect(coordinator.pendingStopRoots == ["/repo"])
        #expect(await coordinator.recover(roots: ["/link/repo"]).interrupted.map(\.opID) == ["R"])
        #expect(await coordinator.recover(roots: ["/repo"]).stops.isEmpty)
        #expect(AppState.launchRestoreRoots(projects: ["/link/repo", "/b"], pending: ["/repo", "/b"])
            == ["/b", "/link/repo", "/repo"])
        #expect(AppState.laterRestoreRoots(history: ["/repo", "/c"], readAtOnce: ["/b", "/repo"]) == ["/c"])
    }

    /// A whole reading without the operation (pruned or expired) drops the
    /// waiting notice; so does a journal's lifetime passing.
    @Test func aPendingNotice_isDropped_whenItsOperationIsGone() async throws {
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "D", stage: Self.cutShort, operation: "discard")
        let readings = Recorded([
            RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
            RestoreRecovery(journals: [undo], settled: [], isIncomplete: false),
            RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
            RestoreRecovery(journals: [undo], settled: [], isIncomplete: true)
        ])
        let clock = Recorded(Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = Self.readingInTurn(readings) { clock.value }

        _ = await coordinator.recover(roots: ["/repo"])
        #expect(coordinator.pendingStopRoots == ["/repo"])
        #expect(await coordinator.recover(roots: ["/repo"]).stops.isEmpty)
        #expect(coordinator.pendingStopRoots.isEmpty)

        _ = await coordinator.recover(roots: ["/repo"])
        #expect(coordinator.pendingStopRoots == ["/repo"])
        clock.value += RestorePendingStopFile.lifetime + 1
        #expect(await coordinator.recover(roots: ["/repo"]).stops.isEmpty)
        #expect(coordinator.pendingStopRoots.isEmpty)
    }

    /// A notice whose operation stays unreadable until the app quits waits
    /// in its file, and the next launch tells it once its operation reads;
    /// one that never reads is never told, and no reading fails for it.
    @Test func aPendingNotice_outlivesARelaunch_andIsToldOnce() async throws {
        try await withTempDir { directory in
            let file = directory.appendingPathComponent(RestorePendingStopFile.fileName)
            let restore = try Self.decodedJournal(root: "/repo", opID: "R")
            let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "R", stage: Self.cutShort)
            let unreadable = RestoreRecovery(journals: [undo], settled: [], isIncomplete: true)

            let first = Self.readingInTurn(Recorded([
                RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
                unreadable,
                unreadable
            ]), pending: file)
            for _ in 0..<3 {
                #expect(await first.recover(roots: ["/repo"]).stops.isEmpty)
            }
            #expect(RestorePendingStopFile.read(file).map(\.settledID) == ["U"])

            // Never readable this launch either: kept, and never told.
            let second = Self.readingInTurn(Recorded([unreadable, unreadable]), pending: file)
            #expect(second.pendingStopRoots == ["/repo"])
            #expect(await second.recover(roots: ["/repo"]).stops.isEmpty)
            #expect(await second.recover(roots: ["/repo"]).stops.isEmpty)

            let third = Self.readingInTurn(Recorded([
                RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false),
                RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false)
            ]), pending: file)
            let told = await third.recover(roots: ["/repo"])
            #expect(told.interrupted.map(\.opID) == ["R"])
            #expect(await third.recover(roots: ["/repo"]).stops.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: file.path))

            let fourth = Self.readingInTurn(Recorded([
                RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false)
            ]), pending: file)
            #expect(fourth.pendingStopRoots.isEmpty)
            #expect(await fourth.recover(roots: ["/repo"]).stops.isEmpty)
        }
    }

    /// Each reading's finds are told as they come, and a worktree a hook
    /// kept locked is read again.
    @Test func recoveryAtLaunch_tellsEachReading_andReadsALockedWorktreeAgain() async throws {
        let stopped = try Self.decodedJournal(root: "/a", opID: "A", stage: Self.cutShort)
        let locked = try Self.decodedJournal(root: "/b", opID: "B", stage: #"{"kind":"writing","done":[]}"#)
        let settledLater = try Self.decodedJournal(root: "/b", opID: "B", stage: Self.cutShort)
        let readings = Recorded<[String]>([])
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { root in
                readings.update { $0.append(root) }
                if root == "/a" {
                    return RestoreRecovery(journals: [stopped], settled: ["A"])
                }
                let isFirst = readings.value.filter { $0 == "/b" }.count == 1
                return isFirst
                    ? RestoreRecovery(journals: [locked], settled: [])
                    : RestoreRecovery(journals: [settledLater], settled: ["B"])
            }
        ))
        var told: [[String]] = []

        await coordinator.recoverAtLaunch(roots: ["/a", "/b"], attempts: 3, retry: .milliseconds(1)) { found in
            told.append(found.interrupted.map(\.opID))
        }

        #expect(told == [["A"], ["B"]])
        #expect(readings.value == ["/a", "/b", "/b"])
    }

    /// A reading of the journals that fails after a restore is not an
    /// empty list: the restore's record keeps its Undo, and the worktree is
    /// read again.
    @Test(.timeLimit(.minutes(1))) func aFailedReadingAfterARestore_keepsItsUndo_andReadsAgain() async throws {
        let restored = try Self.decodedJournal(root: "/repo", opID: "R")
        let readings = Recorded(0)
        let coordinator = RestoreCoordinator(
            stateDirectories: [],
            bridge: .init(
                restore: { _, _, _, _ in .finished(restored) },
                undo: { _, _, _ in .refused(.unknown) },
                recover: { _ in
                    readings.update { $0 += 1 }
                    guard readings.value > 1 else { throw LimpidRestoreBridgeError.rust(-1) }
                    return RestoreRecovery(journals: [restored], settled: [])
                }
            ),
            rereadDelay: .milliseconds(10)
        )
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("a", 1), root: "/repo")
        let turn = try TurnSummaryFixture.turn("T1", extras: extras)

        #expect(await coordinator.restore(turn) == .finished(restored))

        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "R")
        await pollUntil(timeout: .seconds(5)) { readings.value > 1 }
        #expect(readings.value == 2)
        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "R")
    }

    /// A worktree whose journals could not be read at launch is read again,
    /// as one a hook kept locked is.
    @Test func aFailedReadingAtLaunch_isReadAgain() async {
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in throw LimpidRestoreBridgeError.rust(-1) }
        ))

        let report = await coordinator.recover(roots: ["/repo"])

        #expect(report.unsettledRoots == ["/repo"])
    }

    @Test func aTurnWithoutItsStart_isNotSentToRust() async throws {
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in Issue.record("called")
                return .refused(.unknown)
            },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [], settled: []) }
        ))
        let turn = try TurnSummaryFixture.turn("T1")
        #expect(await coordinator.restore(turn) == nil)
    }
}
