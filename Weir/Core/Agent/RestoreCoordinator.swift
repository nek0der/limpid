// RestoreCoordinator.swift
// Weir — runs restores and their undo through Rust off the main actor, and keeps each worktree's journals for the records.

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("restore")

/// Runs restores of a worktree to the start of a turn, and their undo,
/// and keeps what Rust journaled about them, which the
/// restore records show. Rust owns the journals; this only reads them.
///
/// The work runs git and may wait for the worktree lock, so it runs on its
/// own queue (`RestoreRunner`), one operation of a worktree at a time.
@MainActor
@Observable
final class RestoreCoordinator {
    /// The calls into Rust, replaceable in tests.
    struct Bridge: Sendable {
        var restore: @Sendable (_ root: String, _ turnID: TurnID, _ paneID: String, [RestoreStateDirectory]) throws -> RestoreOutcome
        var undo: @Sendable (_ root: String, _ opID: String, [RestoreStateDirectory]) throws -> RestoreOutcome
        var recover: @Sendable (_ root: String) throws -> RestoreRecovery
        var discard: @Sendable (DiscardCall, [RestoreStateDirectory]) throws -> DiscardOutcome = { _, _ in
            throw WeirRestoreBridgeError.rust(-1)
        }

        static let rust = Bridge(
            restore: { try WeirRestoreBridge.restore(root: $0, turnID: $1, paneID: $2, stateDirectories: $3) },
            undo: { try WeirRestoreBridge.undo(root: $0, opID: $1, stateDirectories: $2) },
            recover: { try WeirRestoreBridge.recover(root: $0) },
            discard: { call, directories in
                try WeirRestoreBridge.discard(
                    range: call.range,
                    lastTurnNumber: call.lastTurnNumber,
                    paneID: call.paneID,
                    files: call.files,
                    stateDirectories: directories
                )
            }
        )

        /// Writes nothing and reads no journal, for demo mode: its
        /// worktrees are a fixture's. Every operation is refused with no
        /// reason, which says no file was changed.
        static let inert = Bridge(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [], settled: []) },
            discard: { _, _ in .refused(.unknown) }
        )
    }

    /// What a discard of review hunks names.
    struct DiscardCall: Sendable {
        let range: ReviewTurnRange
        let lastTurnNumber: Int?
        let paneID: String
        let files: [DiscardFile]
    }

    /// Every journal of each worktree read so far, by the worktree's root
    /// as git names it (`rev-parse --show-toplevel`, as a turn's snapshot
    /// records it), oldest first.
    private(set) var journals: [String: [RestoreJournal]] = [:]
    /// The worktrees whose last reading left out journals that are there
    /// but could not be read, by the root each was asked by. What was known
    /// of those stays in `journals`, so nothing reads them as gone; the
    /// worktree is read again until a reading is whole.
    private(set) var incompleteRoots: Set<String> = []
    /// The worktrees with a restore or an undo under way.
    private(set) var busyRoots: Set<String> = []
    /// How the last "Undo Restore" of each worktree fell short, which its
    /// record says until the next operation there.
    private(set) var undoResults: [String: UndoResult] = [:]
    /// Hears each whole reading of a worktree's journals, by the root it
    /// was asked by, with every journal it found: what a restore keeps for
    /// as long as it can be undone lets go of it here
    /// (`ViewedLineStore.settleRestoreMoves`). An incomplete reading is not
    /// told, as a journal it left out may be one it could not read.
    @ObservationIgnored var onWholeReading: (@MainActor (_ root: String, _ journals: [RestoreJournal]) -> Void)?

    @ObservationIgnored private let stateDirectories: [RestoreStateDirectory]
    @ObservationIgnored private let runner: RestoreRunner
    /// The repeated readings of the worktrees whose journals could not be
    /// read after an operation (`reload`), by root.
    @ObservationIgnored private var rereads: [String: Task<Void, Never>] = [:]
    /// How long after a failed reading the next one is tried; injected by
    /// tests.
    @ObservationIgnored private let rereadDelay: Duration
    @ObservationIgnored private let rereadAttempts: Int
    /// The launch notices of undos cut short whose restore or discard could
    /// not be read when recovery settled them, oldest first. Rust names an
    /// operation as settled only in the reading that settled it, so the
    /// notice waits here, and in `pendingStopsURL` across a relaunch, until
    /// a launch reading lists the operation (it is told once, and goes), a
    /// whole reading does not (pruned, expired, or gone), or it is past a
    /// journal's lifetime. Only launch readings (`recover(roots:)`) tell it,
    /// as only they reach the launch toast; one read after an operation
    /// leaves it for the next launch.
    @ObservationIgnored private var pendingStops: [RestorePendingStop]
    /// Where `pendingStops` are kept between launches; `nil` keeps them in
    /// memory only, as demo mode and tests do.
    @ObservationIgnored private let pendingStopsURL: URL?
    /// When a pending notice is taken to begin, and how old one is; injected
    /// by tests.
    @ObservationIgnored private let now: () -> Date

    /// Every provider's state directory under `root`, as the registry
    /// names them.
    static func stateDirectories(under root: URL) -> [RestoreStateDirectory] {
        AgentProviderRegistry.directories(under: root)
            .compactMap { id, directories in
                guard let provider = AgentKind(rawValue: id) else {
                    // Its runs would not be read again under the lock.
                    log.fault("provider \(id, privacy: .public) has no agent kind; a restore will not see its runs")
                    return nil
                }
                return RestoreStateDirectory(provider: provider, directory: directories.state)
            }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    /// `stateDirectories` are every provider's, whose run records Rust
    /// reads again under the lock.
    init(
        stateDirectories: [RestoreStateDirectory],
        bridge: Bridge = .rust,
        rereadDelay: Duration = .seconds(2),
        rereadAttempts: Int = 5,
        pendingStopsURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.stateDirectories = stateDirectories
        runner = RestoreRunner(bridge: bridge)
        self.rereadDelay = rereadDelay
        self.rereadAttempts = rereadAttempts
        self.pendingStopsURL = pendingStopsURL
        self.now = now
        let read = pendingStopsURL.map(RestorePendingStopFile.read) ?? []
        pendingStops = read
        dropExpiredPendingStops()
        if pendingStops != read {
            savePendingStops()
        }
    }

    /// The worktrees whose launch notices wait for their operation to be
    /// read (`pendingStops`), each by the root its journals name: the
    /// launch reads them whether or not a project holds them still.
    var pendingStopRoots: [String] {
        Set(pendingStops.map(\.root)).sorted()
    }

    /// The latest restore of `root` still to be undone, which its record
    /// shows. A discard's undo is its hunk's, in the review.
    func latestUndoable(in root: String) -> RestoreJournal? {
        journals[root]?.last { $0.operation == .restore && $0.isUndoable }
    }

    func isBusy(_ root: String) -> Bool {
        busyRoots.contains(root)
    }

    /// The journal of the operation `opID` of `root`, as last read.
    func journal(_ opID: String, in root: String) -> RestoreJournal? {
        journals[root]?.first { $0.opID == opID }
    }

    /// Restores the worktree the turn began in to the start of the turn.
    /// `nil` when the turn's start was not captured, a restore of the
    /// worktree is already under way, or the bridge could not be called.
    func restore(_ turn: TurnSummary) async -> RestoreOutcome? {
        guard let root = turn.beginTree?.root, !busyRoots.contains(root) else { return nil }
        busyRoots.insert(root)
        defer { busyRoots.remove(root) }
        undoResults[root] = nil
        let outcome = await runner.restore(root: root, turnID: turn.turnID, paneID: turn.paneID, stateDirectories)
        Self.record(outcome, of: "restore")
        await reload(root, after: outcome?.journal)
        return outcome
    }

    /// Discards review hunks. `nil` when an operation of the worktree
    /// is already under way or the bridge could not be called.
    func discard(_ call: DiscardCall) async -> DiscardOutcome? {
        let root = call.range.root
        guard !busyRoots.contains(root) else { return nil }
        busyRoots.insert(root)
        defer { busyRoots.remove(root) }
        let outcome = await runner.discard(call, stateDirectories)
        switch outcome {
        case let .refused(refusal):
            log.info("discard refused: \(String(describing: refusal), privacy: .private)")
        case let .finished(journal, hunks):
            let stage = journal.map { String(describing: $0.stage) } ?? "nothing written"
            log.info("discard of \(hunks.count, privacy: .public) hunks: \(stage, privacy: .private)")
        case nil:
            break
        }
        if case let .finished(journal?, _) = outcome {
            await reload(root, after: journal)
        } else {
            await reload(root, after: nil)
        }
        return outcome
    }

    /// Undoes the restore or the discard `journal` journaled. `nil` when
    /// another operation of the worktree is under way or the bridge could
    /// not be called. How a restore's undo fell short shows on its record
    /// (`undoResults`); a discard's, on its hunk.
    func undo(_ journal: RestoreJournal) async -> RestoreOutcome? {
        let root = journal.root
        guard !busyRoots.contains(root) else { return nil }
        busyRoots.insert(root)
        defer { busyRoots.remove(root) }
        let outcome = await runner.undo(root: root, opID: journal.opID, stateDirectories)
        Self.record(outcome, of: "undo")
        if journal.operation == .restore {
            undoResults[root] = UndoResult(outcome)
        }
        await reload(root, after: outcome?.journal)
        return outcome
    }

    /// How an "Undo Restore" fell short of taking its restore back.
    enum UndoResult: Equatable, Sendable {
        case refused(RestoreRefusal)
        /// It put back part of what the restore wrote; the restore's record
        /// stays, with the rest to undo. `keptAside` are the saves it moved
        /// out of the way.
        case partial(keptAside: [RestoreKeptAside])
        /// Nothing of it is left: another change came while it ran.
        case canceled
        /// How it ended is not known: its journal was read before it
        /// settled, or the bridge failed, perhaps after writing.
        case unknown

        /// Whether another try may end otherwise: one that stopped partway
        /// or whose end is not known, or a refusal that passes once an
        /// agent stops or the person sets the worktree right.
        var mayChange: Bool {
            switch self {
            case .partial, .canceled, .unknown: true
            case let .refused(refusal): !refusal.isLasting
            }
        }

        /// `nil` when the undo took the whole restore back.
        init?(_ outcome: RestoreOutcome?) {
            switch outcome {
            case let .refused(refusal):
                self = .refused(refusal)
            case let .finished(journal):
                switch journal.stage {
                // Whole, saves moved aside or not: where they went is the
                // caller's to say (`RestoreText.keptAsideNews`).
                case _ where journal.stage.isWhole: return nil
                case .applied: return nil
                case let .partiallyApplied(_, _, _, keptAside): self = .partial(keptAside: keptAside)
                case .aborted: self = .canceled
                case .planned, .writing, .verifying, .undone, .unknown: self = .unknown
                }
            case nil:
                self = .unknown
            }
        }
    }

    /// An operation this reading settled that the person is told of at
    /// launch: `settled` as recovery found it, and `undoable`, the one its
    /// Undo takes back (an undo cut short offers its restore or discard,
    /// which still has what the undo did not take back).
    struct RecoveredStop: Equatable {
        let settled: RestoreJournal
        let undoable: RestoreJournal
    }

    /// What reading the journals at launch found.
    struct RecoveryReport: Equatable {
        /// What this reading settled that is told once at launch, with
        /// Undo: an operation or an undo cut short, and a discard that ended
        /// as the app quit (its hunk's undo went with the review).
        var stops: [RecoveredStop] = []
        /// The operations the launch toast's Undo takes back.
        var interrupted: [RestoreJournal] {
            stops.map(\.undoable)
        }

        /// The saves of another writer that the operations this reading
        /// settled moved aside, cut short or not: said once at launch, as
        /// nothing else names them.
        var keptAside: [RestoreKeptAside] = []
        /// Worktrees whose unfinished restores could not be settled (a hook
        /// held the lock), or whose reading was incomplete
        /// (`RestoreRecovery.isIncomplete`), to read again later.
        var unsettledRoots: [String] = []

        /// This report with `later`'s stops and saves added, each once.
        func adding(_ later: Self) -> Self {
            var merged = self
            merged.stops += later.stops.filter { stop in
                !merged.stops.contains { $0.undoable.opID == stop.undoable.opID }
            }
            merged.keptAside += later.keptAside.filter { !merged.keptAside.contains($0) }
            merged.unsettledRoots = later.unsettledRoots
            return merged
        }
    }

    /// Reads each worktree's journals, settling the restores a crash cut
    /// short (at launch, before anything is offered).
    func recover(roots: [String]) async -> RecoveryReport {
        var report = RecoveryReport()
        for root in Set(roots).sorted() {
            // A restore of it is under way, which settles what was cut
            // short first; read it again later all the same.
            guard !busyRoots.contains(root) else {
                report.unsettledRoots.append(root)
                continue
            }
            // Not read: what was known of it stays, and it is read again
            // with those a hook kept locked.
            guard let recovery = await runner.recover(root: root) else {
                report.unsettledRoots.append(root)
                continue
            }
            // An incomplete reading still settled and dropped what it
            // read, and says so: its finds are told now, and the worktree
            // is read again for the rest.
            take(recovery, of: root)
            let settled = Set(recovery.settled)
            // A discard is told whether it was cut short or ended as the app
            // quit: the review that offered its undo closed with the app,
            // and the toast is its only way back.
            let settledToTell = recovery.journals.filter { journal in
                settled.contains(journal.opID)
                    && (journal.stage.isInterrupted
                        || (journal.operation == .discard && journal.undoes == nil && journal.stage.isWhole))
            }
            report.stops += settledToTell
                .filter { $0.undoes == nil && $0.isUndoable }
                .map { RecoveredStop(settled: $0, undoable: $0) }
            // Rust names an undo as settled only in the reading that settled
            // it, so one is queued once and told once; were it named again,
            // it would be queued again.
            report.stops += resolvePendingStops(
                readOf: root,
                recovery,
                settledUndos: settledToTell.filter { $0.undoes != nil }
            )
            report.keptAside += recovery.journals
                .filter { settled.contains($0.opID) }
                .flatMap(\.stage.keptAside)
            if recovery.isIncomplete || recovery.journals.contains(where: \.stage.isUnfinished) {
                report.unsettledRoots.append(root)
            }
        }
        return report
    }

    /// The launch notices that the reading `recovery` of `root`, already
    /// taken in, settles, after `settledUndos` (the undos it settled) are
    /// added to `pendingStops`: told when it lists the operation as one to
    /// undo, dropped when it lists it as no longer so, or, whole, does not
    /// list it (pruned, expired, or gone). An incomplete one keeps the rest
    /// waiting, as the operation may be one it could not read.
    private func resolvePendingStops(
        readOf root: String,
        _ recovery: RestoreRecovery,
        settledUndos: [RestoreJournal]
    ) -> [RecoveredStop] {
        let before = pendingStops
        dropExpiredPendingStops()
        for undo in settledUndos {
            guard let undoes = undo.undoes,
                  !pendingStops.contains(where: { $0.root == undo.root && $0.settledID == undo.opID })
            else { continue }
            pendingStops.append(RestorePendingStop(root: undo.root, settledID: undo.opID, undoableID: undoes, since: now()))
        }
        let read = Set(recovery.journals.map(\.root)).union([root])
        var told: [RecoveredStop] = []
        var waiting: [RestorePendingStop] = []
        for stop in pendingStops {
            guard read.contains(stop.root) else {
                waiting.append(stop)
                continue
            }
            // As the coordinator knows them now: an incomplete reading keeps
            // what was known of the ones it left out.
            switch (journal(stop.undoableID, in: stop.root), journal(stop.settledID, in: stop.root)) {
            case let (undoable?, settled?):
                if undoable.isUndoable {
                    told.append(RecoveredStop(settled: settled, undoable: undoable))
                } else {
                    log.info("restore notice \(stop.settledID, privacy: .public): nothing left to undo; dropped")
                }
            case _ where recovery.isIncomplete:
                waiting.append(stop)
            default:
                log.info("restore notice \(stop.settledID, privacy: .public): its journals are gone; dropped")
            }
        }
        pendingStops = waiting
        if pendingStops != before {
            savePendingStops()
        }
        return told
    }

    /// Drops the pending notices past a journal's lifetime: by then their
    /// operation is gone, or is one whose own record offers its Undo.
    private func dropExpiredPendingStops() {
        let now = now()
        pendingStops.removeAll { now.timeIntervalSince($0.since) > RestorePendingStopFile.lifetime }
    }

    private func savePendingStops() {
        if let pendingStopsURL {
            RestorePendingStopFile.write(pendingStops, to: pendingStopsURL)
        }
    }

    /// How an operation ended, for the log: the person sees it in the
    /// record, and the log says why one was refused.
    private static func record(_ outcome: RestoreOutcome?, of operation: String) {
        switch outcome {
        case let .refused(refusal):
            log.info("\(operation, privacy: .public) refused: \(String(describing: refusal), privacy: .private)")
        case let .finished(journal):
            let stage = String(describing: journal.stage)
            log.info("\(operation, privacy: .public) \(journal.opID, privacy: .public): \(stage, privacy: .private)")
        case nil:
            break
        }
    }

    /// Reads `roots` at launch (`recover(roots:)`), and again, up to
    /// `attempts` times `retry` apart, those a hook kept locked. `found`
    /// hears each reading's finds as they come, so one worktree's lock
    /// keeps no other's news waiting.
    func recoverAtLaunch(
        roots: [String],
        attempts: Int,
        retry: Duration,
        found: @MainActor (RecoveryReport) -> Void
    ) async {
        var pending = roots
        for attempt in 0..<attempts where !pending.isEmpty {
            if attempt > 0 {
                try? await Task.sleep(for: retry)
            }
            let report = await recover(roots: pending)
            if !report.interrupted.isEmpty || !report.keptAside.isEmpty {
                found(report)
            }
            pending = report.unsettledRoots
        }
    }

    /// Reads `root`'s journals again after an operation there, which wrote
    /// `written` when it wrote one. A reading that fails is no empty list:
    /// the journals known stay, with `written` among them, so the record
    /// keeps its "Undo Restore", and the worktree is read again shortly.
    private func reload(_ root: String, after written: RestoreJournal?) async {
        rereads[root]?.cancel()
        rereads[root] = nil
        guard let recovery = await runner.recover(root: root) else {
            if let written {
                remember(written)
            }
            rereadLater(root)
            return
        }
        // Left out, not gone: the one this operation wrote stays known when
        // it was among those left out, and the reading's own stands for it
        // when it was not.
        if recovery.isIncomplete, let written {
            remember(written)
        }
        take(recovery, of: root)
        if recovery.isIncomplete {
            rereadLater(root)
        }
    }

    /// Reads `root` again, `rereadDelay` apart, until a reading is whole
    /// or `rereadAttempts` have failed or been incomplete; each incomplete
    /// one is taken in. The next operation there reads it in any case.
    private func rereadLater(_ root: String) {
        rereads[root] = Task { [weak self, rereadDelay, rereadAttempts] in
            for _ in 0..<rereadAttempts {
                try? await Task.sleep(for: rereadDelay)
                guard !Task.isCancelled, let self else { return }
                if let recovery = await runner.recover(root: root) {
                    guard !Task.isCancelled else { return }
                    take(recovery, of: root)
                    // An incomplete one is taken in, and read again.
                    if !recovery.isIncomplete {
                        rereads[root] = nil
                        return
                    }
                }
            }
            log.error("restore journals of a worktree still unreadable or incomplete; kept as last read")
        }
    }

    /// Puts `journal` in its worktree's list, in place of its earlier
    /// reading when there was one.
    private func remember(_ journal: RestoreJournal) {
        var list = journals[journal.root] ?? []
        if let index = list.firstIndex(where: { $0.opID == journal.opID }) {
            list[index] = journal
        } else {
            list.append(journal)
        }
        journals[journal.root] = list
    }

    /// Takes in a reading of the worktree asked by `root`. A whole one
    /// stands for every journal there is. An incomplete one stands for the
    /// journals it read: those known that it left out stay, as they may be
    /// the ones it could not read, and the worktree stays marked
    /// (`incompleteRoots`). One the reading dropped past its lifetime stays
    /// too until a whole reading: it is final, so it offers no Undo.
    private func take(_ recovery: RestoreRecovery, of root: String) {
        guard recovery.isIncomplete else {
            incompleteRoots.remove(root)
            journals[root] = nil
            store(recovery.journals)
            onWholeReading?(root, recovery.journals)
            return
        }
        if !incompleteRoots.contains(root) {
            log.error("some restore journals of a worktree could not be read; the others were read")
        }
        incompleteRoots.insert(root)
        for journal in recovery.journals {
            remember(journal)
        }
        for read in Set(recovery.journals.map(\.root)).union([root]) {
            if let list = journals[read] {
                journals[read] = Self.byWhenRan(list)
            }
        }
    }

    /// `list` oldest first by when each ran, as Rust orders a reading: the
    /// latest undoable restore is the last of them.
    private static func byWhenRan(_ list: [RestoreJournal]) -> [RestoreJournal] {
        list.sorted { ($0.ranAt, $0.opID) < ($1.ranAt, $1.opID) }
    }

    /// Files `read` under the root each journal names, which is git's
    /// spelling of the worktree whatever path it was asked by.
    private func store(_ read: [RestoreJournal]) {
        for (root, list) in Dictionary(grouping: read, by: \.root) {
            journals[root] = list
        }
    }
}

/// Where the bridge calls run: git runs synchronously in them, so they keep
/// to their own queue rather than holding a thread of the shared pool.
private actor RestoreRunner {
    private let bridge: RestoreCoordinator.Bridge
    private let queue = DispatchSerialQueue(label: "com.nekoder.weir.restore", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(bridge: RestoreCoordinator.Bridge) {
        self.bridge = bridge
    }

    func restore(root: String, turnID: TurnID, paneID: String, _ directories: [RestoreStateDirectory]) -> RestoreOutcome? {
        do {
            return try bridge.restore(root, turnID, paneID, directories)
        } catch {
            log.error("restore failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    func discard(_ call: RestoreCoordinator.DiscardCall, _ directories: [RestoreStateDirectory]) -> DiscardOutcome? {
        do {
            return try bridge.discard(call, directories)
        } catch {
            log.error("discard failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    func undo(root: String, opID: String, _ directories: [RestoreStateDirectory]) -> RestoreOutcome? {
        do {
            return try bridge.undo(root, opID, directories)
        } catch {
            log.error("undo of a restore failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// The journals of `root`; `nil` when the bridge could not be called,
    /// which is logged. Never an empty list in its place: that would read
    /// as a worktree with no journal, and lose the Undo of one it has.
    func recover(root: String) -> RestoreRecovery? {
        do {
            return try bridge.recover(root)
        } catch {
            log.error("reading restore journals failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}

private extension RestoreOutcome {
    /// The journal the operation wrote; `nil` for one refused.
    var journal: RestoreJournal? {
        if case let .finished(journal) = self {
            journal
        } else {
            nil
        }
    }
}
