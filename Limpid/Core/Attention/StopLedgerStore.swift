// StopLedgerStore.swift
// Limpid — keeps the stops until their conversation is back, across launches in stops.json.

import Foundation
import Observation
import OSLog

private let log = Logger.limpid("stop-ledger")

/// The app's `StopLedger`, and the clock of each resume: one whose command
/// returned to the shell at once with no run of the conversation, or that has not
/// brought its conversation back within `resumeTimeout`, is a failed one,
/// whose stop offers "Resume Same Conversation" again.
///
/// The stops are kept in `stops.json` between launches. A stop is the
/// person's to end: a run that died at work leaves no record once it
/// is retired, so after a relaunch nothing but this file says the pane
/// holds a conversation that stopped. The file holds the stops and the
/// ones the person moved on from; a resume on its way at quit is not, as
/// the shell it was typed into is gone with the launch, so its stop
/// offers the resume afresh. The resumes typed at launch are of
/// their launch only and are never written.
@MainActor
@Observable
final class StopLedgerStore {
    /// What the file holds.
    private struct Document: Codable, Equatable {
        static let currentVersion = 1
        var schemaVersion = Self.currentVersion
        var records: [StoredRecord] = []
        var dismissed: [AttentionItemID] = []

        init(records: [StoredRecord] = [], dismissed: [AttentionItemID] = []) {
            self.records = records
            self.dismissed = dismissed
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            // One stop this build cannot read (a reason a newer build
            // added) costs that stop, not every other.
            records = try container.decode([Lenient<StoredRecord>].self, forKey: .records).compactMap(\.value)
            dismissed = try container.decodeIfPresent([Lenient<AttentionItemID>].self, forKey: .dismissed)?
                .compactMap(\.value) ?? []
        }
    }

    /// An element that reads as `nil` rather than failing its array.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    /// One stop as the file holds it: the ledger's record with its reason
    /// spelled out by kind, so a reason this build does not know is one
    /// record dropped rather than a file that does not read.
    private struct StoredRecord: Codable, Equatable {
        var itemID: AttentionItemID
        var runtimeID: String
        var provider: AgentKind
        var paneID: UUID
        var conversation: ConversationKey?
        var sessionID: String?
        var cwd: String?
        var turnID: TurnID?
        var reason: StoredReason
        var stoppedAt: Date
        /// Whether the last resume failed (`StopLedger.Resume.failed`),
        /// which the bar says; a resume on its way at quit is neither.
        var resumeFailed: Bool

        init?(_ record: StopLedger.Record) {
            guard let reason = StoredReason(record.reason) else { return nil }
            itemID = record.itemID
            runtimeID = record.runtimeID
            provider = record.provider
            paneID = record.paneID
            conversation = record.conversation
            sessionID = record.sessionID
            cwd = record.cwd
            turnID = record.turnID
            self.reason = reason
            stoppedAt = record.stoppedAt
            resumeFailed = record.resume == .failed
        }

        var record: StopLedger.Record? {
            guard let reason = reason.stopReason else { return nil }
            return StopLedger.Record(
                itemID: itemID,
                runtimeID: runtimeID,
                provider: provider,
                paneID: paneID,
                conversation: conversation,
                sessionID: sessionID,
                cwd: cwd,
                turnID: turnID,
                reason: reason,
                stoppedAt: stoppedAt,
                resume: resumeFailed ? .failed : .none
            )
        }
    }

    /// A stop's reason by kind. Only the reasons a run's stop can have:
    /// a launch failure and a missing worktree are listed from their own
    /// stores, never kept here.
    private struct StoredReason: Codable, Equatable {
        var kind: String
        var message: String?
        var usageLimit: UsageLimit?

        init?(_ reason: StopReason) {
            switch reason {
            case .processExited:
                kind = "processExited"
            case let .error(message):
                kind = "error"
                self.message = message
            case let .usageLimit(limit):
                kind = "usageLimit"
                usageLimit = limit
            case .notResumedAtLaunch:
                kind = "notResumedAtLaunch"
            case .launchFailed, .worktreeMissing:
                return nil
            }
        }

        var stopReason: StopReason? {
            switch kind {
            case "processExited": .processExited
            case "error": .error(message)
            case "usageLimit": usageLimit.map(StopReason.usageLimit)
            case "notResumedAtLaunch": .notResumedAtLaunch
            default: nil
            }
        }
    }

    /// The version check every versioned store shares; this file has no
    /// older shape to bring forward yet.
    private static let migrator = VersionedDocumentMigrator(
        versionKey: "schemaVersion",
        currentVersion: Document.currentVersion,
        versionWhenAbsent: nil,
        steps: []
    )

    private(set) var ledger = StopLedger()
    /// How each stop can be resumed from what its pane shows now, which
    /// the bar draws and the button checks again (`StopResumeRules`). Kept
    /// here, not read while drawing: the job in front of a pane changes
    /// with no event of its own (the agent exits, an editor opens).
    private(set) var offers: [AttentionItemID: DecisionBarContent.StopResume] = [:]
    /// The stops whose pane can start a new conversation now: the shell at
    /// its prompt with nothing half typed, as for a resume.
    private(set) var startsNew: Set<AttentionItemID> = []
    /// Why each other stop's pane cannot, which its disabled ⋯ item says.
    private(set) var newConversationBlockers: [AttentionItemID: DecisionBarContent.ResumeBlocker] = [:]
    /// How long a resume has to bring its conversation back before it
    /// counts as failed, unless a test sets its own.
    nonisolated static let defaultResumeTimeout: Duration = .seconds(45)
    @ObservationIgnored private let resumeTimeout: Duration
    @ObservationIgnored private var timeouts: [AttentionItemID: Task<Void, Never>] = [:]
    /// Told when a resume's deadline passed, so the bar and the list say
    /// at once what came of it.
    @ObservationIgnored var onResumeTimedOut: (@MainActor () -> Void)?
    /// Whether the agent is the job in front of the pane's terminal, read
    /// at a resume's deadline: the resume took when it is (the Codex TUI
    /// reports nothing until its first prompt, `StopLedger.launchResumeTimedOut`),
    /// and failed when it is not. The agent itself: behind a tmux client,
    /// what its pane runs (`AgentForeground.isAgentRunning`), which may take
    /// the person's tmux server a moment to say, hence `async`. `nil` reads
    /// as not in front, for a store with no terminals (the ledger's tests).
    @ObservationIgnored var isAgentInFront: (@MainActor (UUID, AgentKind) async -> Bool)?
    /// True for a launch whose session could not be restored from its
    /// file (`AppState.sessionLoadIssue`): the panes the stops name are
    /// not back through no doing of the person's, so no stop ends for
    /// want of its pane, and the file keeps them for the launch that
    /// restores it. Set by the app before the first `update`.
    @ObservationIgnored var keepsStopsWithoutPanes = false
    @ObservationIgnored private let fileURL: URL
    /// The save waiting out its delay (the coalescing one, or the wait
    /// before a failed write is tried again); `nil` once it went to the
    /// save queue or was flushed.
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Serial, so the writes land in the order they were made. Given by
    /// the tests that hold a write under way while the ledger changes.
    @ObservationIgnored private let saveQueue: DispatchQueue
    /// False in demo mode and in tests of the ledger alone: the stops are
    /// kept in memory only, and the person's own file is neither read nor
    /// written.
    @ObservationIgnored private let writesFiles: Bool
    /// False after finding a newer build's file: its stops are listed when
    /// they can be read, but rewriting it in this version's shape could
    /// drop what it added.
    @ObservationIgnored private var isWritable = true
    /// What the file holds as far as we know: what `load` read, then each
    /// write that landed. A write that failed (a full disk, a read-only
    /// folder) leaves it as it was, so the same stops are written again,
    /// and at quit, rather than taken for written.
    @ObservationIgnored private var onDisk = Document()
    /// What the save waiting or under way carries, so a change of the
    /// ledger that leaves the file the same (a resume on its way) schedules
    /// nothing again; `nil` when none is.
    @ObservationIgnored private var scheduled: Document?
    /// Each write's number, so a write's outcome that reaches the main
    /// actor after a later one's (a flush at quit) is not taken for the
    /// file's.
    @ObservationIgnored private var writeCount = 0
    @ObservationIgnored private var landedWrite = 0
    /// Whether the last write failed: a disk that stays full or read-only
    /// is logged once, not at every try.
    @ObservationIgnored private var isFailing = false
    @ObservationIgnored private let retryDelay: Duration

    /// Whether a resume is still waiting on its time, for tests.
    var hasResumeClock: Bool {
        !timeouts.isEmpty
    }

    /// Whether a write went to the save queue and its outcome has not come
    /// back: the file will hold that write's stops once it lands, which
    /// `onDisk` does not know yet.
    var hasWriteUnderWay: Bool {
        writeCount > landedWrite
    }

    /// A store with no file, for the ledger's own tests.
    convenience init(resumeTimeout: Duration = StopLedgerStore.defaultResumeTimeout) {
        self.init(directory: LimpidPaths.applicationSupportDirectory(), writesFiles: false, resumeTimeout: resumeTimeout)
    }

    convenience init(writesFiles: Bool) {
        self.init(directory: LimpidPaths.applicationSupportDirectory(), writesFiles: writesFiles)
    }

    init(
        directory: URL,
        writesFiles: Bool = true,
        resumeTimeout: Duration = StopLedgerStore.defaultResumeTimeout,
        retryDelay: Duration = .seconds(10),
        saveQueue: DispatchQueue = DispatchQueue(label: "dev.limpid.stop-ledger")
    ) {
        self.saveQueue = saveQueue
        self.resumeTimeout = resumeTimeout
        self.retryDelay = retryDelay
        self.writesFiles = writesFiles
        self.fileURL = directory.appendingPathComponent("stops.json")
        if writesFiles {
            SecureFileWrite.ensureUserOnlyDirectory(directory)
            load()
        }
    }

    /// Takes in the runtimes (`StopLedger.update`). Written only when the
    /// ledger changes: the decision bars read it.
    func update(
        runtimes: [RuntimeFact],
        paneExists: (UUID) -> Bool,
        cwd: (RuntimeFact) -> String? = { _ in nil }
    ) -> StopLedger.Ended {
        var next = ledger
        let ended = next.update(
            runtimes: runtimes,
            paneExists: { [keepsStopsWithoutPanes] in keepsStopsWithoutPanes || paneExists($0) },
            cwd: cwd
        )
        if next != ledger {
            ledger = next
            persist()
        }
        // A clock whose stop ended goes with it. A resume typed at launch
        // has no stop until it fails, so its clock stays while the launch
        // resume does: it is what makes the stop if nothing else does.
        let launchClocks = Set(ledger.launchResumes.values.map {
            StopLedger.launchResumeItemID(paneID: $0.paneID, sessionID: $0.sessionID)
        })
        for itemID in timeouts.keys where ledger.record(itemID) == nil && !launchClocks.contains(itemID) {
            timeouts.removeValue(forKey: itemID)?.cancel()
        }
        return ended
    }

    /// Each stop's resume, and what keeps it from starting a new
    /// conversation (`nil` when nothing does), from `read`; written only
    /// when they change.
    func refreshOffers(
        _ read: (StopLedger.Record) -> (resume: DecisionBarContent.StopResume, newConversation: DecisionBarContent.ResumeBlocker?)
    ) {
        var next: [AttentionItemID: DecisionBarContent.StopResume] = [:]
        var nextStartsNew: Set<AttentionItemID> = []
        var nextBlockers: [AttentionItemID: DecisionBarContent.ResumeBlocker] = [:]
        for record in ledger.records.values {
            let offer = read(record)
            next[record.itemID] = offer.resume
            if let blocker = offer.newConversation {
                nextBlockers[record.itemID] = blocker
            } else {
                nextStartsNew.insert(record.itemID)
            }
        }
        if next != offers {
            offers = next
        }
        if nextStartsNew != startsNew {
            startsNew = nextStartsNew
        }
        if nextBlockers != newConversationBlockers {
            newConversationBlockers = nextBlockers
        }
    }

    /// Ends a stop the person moved on from, and its resume's clock.
    func dismiss(_ itemID: AttentionItemID) {
        ledger.dismiss(itemID)
        timeouts.removeValue(forKey: itemID)?.cancel()
        persist()
    }

    /// The stops the attention list keeps for runs that no longer report
    /// them, in the tab their pane is in now.
    func retained(besides runtimes: [RuntimeFact], session: WorkspaceSession) -> [AttentionQueueReducer.RetainedStop] {
        ledger.retained(besides: runtimes).map { record in
            let tab = session.tab(containing: record.paneID)
            return AttentionQueueReducer.RetainedStop(
                itemID: record.itemID,
                runtimeID: record.runtimeID,
                provider: record.provider,
                paneID: record.paneID,
                tabID: tab?.id,
                projectID: tab?.container.projectID,
                reason: record.reason,
                stoppedAt: record.stoppedAt
            )
        }
    }

    /// The shell integration reported a command of `paneID` finished, one
    /// that ran for `durationNs` and exited with `exitCode`. A resume typed
    /// into that pane before the command began is over: failed when the
    /// command came back at once, taken when it ran for longer
    /// (`StopLedger.resumeCommandFinished`), and needs no deadline now.
    /// Returns what came of the resume.
    @discardableResult
    func resumeCommandFinished(
        inPane paneID: UUID,
        exitCode: Int,
        durationNs: UInt64,
        now: Date = Date()
    ) -> StopLedger.ResumeCommandEnd? {
        guard !ledger.records.isEmpty || !ledger.launchResumes.isEmpty else { return nil }
        let runTime = Double(durationNs) / 1_000_000_000
        let startedAt = now.addingTimeInterval(-runTime)
        guard let end = ledger.resumeCommandFinished(inPane: paneID, startedAt: startedAt, runTime: runTime) else { return nil }
        timeouts.removeValue(forKey: end.itemID)?.cancel()
        switch end {
        case .failed:
            log.notice("resume returned to the shell before its conversation: exit=\(exitCode, privacy: .public)")
        case .cameBack:
            log.notice("resume came back, then its agent was quit: ran=\(Int(runTime), privacy: .public)s")
        }
        persist()
        return end
    }

    /// The resume was typed into the pane: the stop waits for its
    /// conversation, for `resumeTimeout` at most, or until its command
    /// returns to the shell (`resumeCommandFinished`). At the deadline,
    /// the agent in front of the pane is the conversation back, and the
    /// stop ends; the shell there is the resume failed. Asked from
    /// `window`, whose bar says it is back; `nil` when no window asked.
    func markResuming(_ itemID: AttentionItemID, window: WindowID?, now: Date = Date()) {
        ledger.markResuming(itemID, at: now, window: window)
        persist()
        timeouts.removeValue(forKey: itemID)?.cancel()
        let timeout = resumeTimeout
        timeouts[itemID] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            var isAgentInFront = false
            if let record = ledger.record(itemID) {
                isAgentInFront = await agentIsInFront(of: record.paneID, record.provider)
            }
            // The resume may have ended while tmux was asked (its command
            // came back): this clock is no longer its.
            guard !Task.isCancelled else { return }
            ledger.resumeTimedOut(itemID, since: now, isAgentInFront: isAgentInFront)
            timeouts[itemID] = nil
            persist()
            onResumeTimedOut?()
        }
    }

    /// Whether `provider` is in front of `paneID`'s terminal now, as the
    /// app reads it; not in front when nothing reads terminals.
    private func agentIsInFront(of paneID: UUID, _ provider: AgentKind) async -> Bool {
        let isInFront = await isAgentInFront?(paneID, provider) ?? false
        log.notice("resume deadline: agent in front=\(isInFront, privacy: .public) provider=\(provider.rawValue, privacy: .public)")
        return isInFront
    }

    /// Limpid typed the resume of `sessionID` into the restored `paneID` at
    /// `now`: watched as a resume from the bar is, for `resumeTimeout`
    /// at most or until its command returns to the shell, and listed as a
    /// stop only once it failed (`StopLedger.LaunchResume`): at the
    /// deadline with no agent in front of the pane. Told by the
    /// pane's terminal once the command is typed
    /// (`SurfaceView.onInitialCommandTyped`), never before: a pane whose
    /// terminal never typed it has no resume to fail, and the clock runs
    /// from the keys, not from the view.
    func markResumingAtLaunch(paneID: UUID, provider: AgentKind, sessionID: String, cwd: String?, now: Date = Date()) {
        ledger.markResumingAtLaunch(paneID: paneID, provider: provider, sessionID: sessionID, cwd: cwd, at: now)
        // A stop kept from the last launch that this resume took over is
        // no longer a failed one in the file.
        persist()
        let itemID = StopLedger.launchResumeItemID(paneID: paneID, sessionID: sessionID)
        timeouts.removeValue(forKey: itemID)?.cancel()
        let timeout = resumeTimeout
        timeouts[itemID] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            let isAgentInFront = await agentIsInFront(of: paneID, provider)
            // Ended while tmux was asked, as above.
            guard !Task.isCancelled else { return }
            ledger.launchResumeTimedOut(paneID: paneID, since: now, isAgentInFront: isAgentInFront)
            timeouts[itemID] = nil
            persist()
            onResumeTimedOut?()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            if case .newer = try Self.migrator.migrate(data) {
                // Read for its stops, which are listed as any, and left
                // as it is.
                isWritable = false
            }
            let document = try PersistenceCoders.makeDecoder().decode(Document.self, from: data)
            ledger = StopLedger(
                restoring: document.records.compactMap(\.record),
                dismissed: Set(document.dismissed)
            )
            onDisk = Self.document(of: ledger)
            log.notice("stops kept from the last launch: \(document.records.count, privacy: .public)")
        } catch {
            // Unreadable stops cost the stops of the last launch, whose
            // panes stay as the shells they are; nothing is listed that
            // did not stop.
            log.error("stops unreadable: \(String(describing: error), privacy: .private)")
        }
    }

    /// The file's shape of `ledger`: its stops in a fixed order, so two
    /// ledgers that hold the same stops make the same document.
    private static func document(of ledger: StopLedger) -> Document {
        Document(
            records: ledger.records.values
                .sorted { $0.stoppedAt != $1.stoppedAt ? $0.stoppedAt < $1.stoppedAt : $0.runtimeID < $1.runtimeID }
                .compactMap(StoredRecord.init),
            dismissed: ledger.dismissed.sorted { String(describing: $0) < String(describing: $1) }
        )
    }

    /// Saves the ledger shortly, when what the file holds changed.
    private func persist() {
        guard writesFiles, isWritable else { return }
        let document = Self.document(of: ledger)
        guard document != (scheduled ?? onDisk) else { return }
        schedule(document, after: PersistenceTiming.coalescing)
    }

    /// Writes `document` once `delay` is over, unless a later save replaces
    /// it. The wait is on the main actor, where the save is forgotten once
    /// it goes; only the write itself goes to the save queue, as in the
    /// other stores, and its outcome comes back here.
    private func schedule(_ document: Document, after delay: Duration) {
        pendingSave?.cancel()
        scheduled = document
        let url = fileURL
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            pendingSave = nil
            writeCount += 1
            let number = writeCount
            saveQueue.async { [weak self] in
                let error = Self.write(document, to: url)
                // In order on the main queue, as the writes were made.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.didWrite(document, number: number, error: error)
                    }
                }
            }
        }
    }

    /// A write's outcome. One that failed is tried again after
    /// `retryDelay`, with the ledger as it is then, unless a later save is
    /// already waiting; the stops are the person's to end, not the
    /// disk's.
    private func didWrite(_ document: Document, number: Int, error: String?) {
        guard number > landedWrite else { return }
        landedWrite = number
        if let error {
            if !isFailing {
                log.error("write stops: \(error, privacy: .private)")
            }
            isFailing = true
        } else {
            onDisk = document
            if isFailing {
                log.notice("stops written again")
            }
            isFailing = false
        }
        guard pendingSave == nil else { return }
        scheduled = nil
        let current = Self.document(of: ledger)
        if current != onDisk {
            schedule(current, after: error == nil ? PersistenceTiming.coalescing : retryDelay)
        }
    }

    /// Writes on the save queue; a value-typed document, so nothing on the
    /// main actor is touched. Returns why it failed, in words that cross to the main actor; `nil` once written.
    private nonisolated static func write(_ document: Document, to url: URL) -> String? {
        do {
            let data = try PersistenceCoders.makeEncoder().encode(document)
            try SecureFileWrite.writeAtomic(data, to: url)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// Writes the ledger now when the file does not hold it, for quitting
    /// and for tests: a save waiting, or one that failed, lands here. On the
    /// save queue, so a write already under way there finishes first and
    /// cannot land after this one with older stops. With a write under way,
    /// the ledger is written whatever `onDisk` says: that write carries the
    /// stops of when it was made, which can differ from both (a stop that
    /// began and ended since), and the file must hold what lands last.
    func flushSynchronously() {
        guard writesFiles, isWritable else { return }
        pendingSave?.cancel()
        pendingSave = nil
        scheduled = nil
        let document = Self.document(of: ledger)
        let needsWrite = document != onDisk || hasWriteUnderWay
        let url = fileURL
        let error = saveQueue.sync { needsWrite ? Self.write(document, to: url) : nil }
        guard needsWrite else { return }
        writeCount += 1
        didWrite(document, number: writeCount, error: error)
    }
}
