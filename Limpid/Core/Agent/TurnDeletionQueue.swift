// TurnDeletionQueue.swift
// Limpid — which turn deletions are on their way or waiting, and what a finished batch leaves behind.

import Foundation

/// The adapter's record of the turns the retention sweep asked to delete:
/// which are on their way, which wait after a refusal, and each one's
/// conversation as the history had it when it was asked for.
///
/// A value, so what a pass asks for and what a finished batch reports are
/// worked out without the adapter or the collector. The batch with the
/// collector is also kept in a file (`TurnDeletionFile`), so a deletion a
/// quit cuts short is reported at the next launch with what it was.
struct TurnDeletionQueue {
    /// What a finished batch hands the host.
    struct Report: Equatable {
        /// The turns gone, each with its conversation when it was known.
        var gone: [TurnID: ConversationKey?]
        /// The conversations that still have turns: not deleted after all,
        /// or still on their way, moved aside out of the history for now.
        var remaining: Set<ConversationKey>
        /// By the worktree their snapshots were taken in, when the turns
        /// gone ran (`Span`).
        var deletedIn: [String: [DateInterval]] = [:]
        /// These are the turns whose spans make up `deletedIn`. The file keeps them
        /// until the host says those spans are saved (`spansSaved`).
        var spanTurnIDs: [String] = []
    }

    /// Where and when a turn asked for ran: the worktree its snapshots were
    /// taken in, and from its start to its end. Once it is gone, a gap
    /// between the turns left there that it fell in holds what it changed,
    /// which must not be counted as changed outside turns, and no
    /// record is left to say which gap that was.
    struct Span: Codable, Equatable, Sendable {
        let root: String
        let interval: DateInterval

        /// The span of `turn` as the history has it; none without a
        /// snapshot or a time to place it by. A record from before end
        /// times were kept is placed at its start.
        static func of(_ turn: TurnSummary) -> Span? {
            guard let root = (turn.endTree ?? turn.beginTree)?.root,
                  let start = UnreadTurnRules.date(turn.startedAt)
            else { return nil }
            let end = turn.finishedAt.flatMap(UnreadTurnRules.date) ?? start
            return Span(root: root, interval: DateInterval(start: start, end: max(start, end)))
        }
    }

    /// One directory's turns, asked for by one pass.
    struct Batch: Equatable {
        let directory: URL
        let turnIDs: [String]
        /// What protected turns when the sweep chose these: whether they
        /// may still go is the sweep's to say, so a batch goes only while
        /// nothing protects more than it did then.
        let sweptWith: TurnProtection
    }

    /// What `nextBatch` decided.
    struct Next: Equatable {
        /// The batch to send now, if any.
        var batch: Batch?
        /// Whether a batch was dropped because more is protected now: a
        /// pass should sweep again with what protects turns now.
        var needsSweep = false
    }

    /// How long a turn not deleted waits before it is asked for again.
    static let retryDelay: TimeInterval = 10 * 60

    /// Batches asked for and not sent yet, oldest first. One goes to the
    /// collector at a time, so each is checked against what protects turns
    /// just before it goes rather than when it was asked for: one waits
    /// behind another that runs git, and a person may open its turns in a
    /// review meanwhile. A turn opened while its own batch is with
    /// the collector is not covered: a batch runs one git command per
    /// repository, and a review that loses that race says its snapshots
    /// are gone rather than showing something else.
    private(set) var waiting: [Batch] = []
    /// Whether a batch is with the collector now; set by `nextBatch` and
    /// cleared by `finished`.
    private(set) var isSending = false

    /// Whether `nextBatch` has anything to decide. The protection it takes
    /// walks every turn, so the caller asks this first.
    var hasBatchToSend: Bool {
        !isSending && !waiting.isEmpty
    }

    /// The turns a batch is deleting now.
    private(set) var inFlight: Set<String> = []
    /// When a turn not deleted may be asked for again.
    private(set) var retryAfter: [String: Date] = [:]
    /// Whether the last pass read every turn record: the history it built
    /// may lack conversations otherwise.
    var isHistoryComplete = false
    private var conversations: [String: ConversationKey] = [:]
    private var spans: [String: Span] = [:]
    /// The batch with the collector now, kept in the file until it reports.
    private var sending: Batch?
    /// The turns an earlier run had with the collector when it ended, read
    /// from the file: their report was cut off, and the launch finishes
    /// them before any history knows them (`recovered`).
    private var unheard: [String: TurnDeletionEntry] = [:]
    /// These are the turns gone whose spans the host has not yet said are
    /// saved. We keep them in the file, without their conversation, which
    /// the report already handed over: the spans are saved a moment after the
    /// report (`ViewedLineStore.noteDeletedTurns`), and a quit in between
    /// would otherwise lose them, with no record left to say when the
    /// turn ran. The next launch finds their records gone and reports
    /// their spans again.
    private var unsaved: [String: TurnDeletionEntry] = [:]
    /// Where the turns with the collector are kept between launches; `nil`
    /// keeps them in memory only, as a run that writes no files does.
    let url: URL?

    init(url: URL? = nil) {
        self.url = url
        let entries = url.map(TurnDeletionFile.read) ?? []
        unheard = Dictionary(entries.map { ($0.turnID, $0) }) { first, _ in first }
    }

    /// Forgets the waits that have passed, so the record holds only turns
    /// still waiting.
    mutating func forgetPastWaits(now: Date) {
        retryAfter = retryAfter.filter { $0.value > now }
    }

    /// Whether `turnID` may be asked for: one on its way, or refused a moment
    /// ago, is not, or every pass would ask again.
    func mayAsk(_ turnID: String) -> Bool {
        !inFlight.contains(turnID) && retryAfter[turnID] == nil
    }

    /// Notes `turnIDs` as asked for, each with its conversation now: by the
    /// time the batch reports, a pass may have read the directory without
    /// the records it moved aside, and the history with them.
    mutating func asked(
        _ turnIDs: [String],
        spans newSpans: [String: Span] = [:],
        conversation: (String) -> ConversationKey?
    ) {
        for turnID in turnIDs {
            inFlight.insert(turnID)
            conversations[turnID] = conversation(turnID)
            spans[turnID] = newSpans[turnID]
        }
    }

    /// Notes `turnIDs`, which the sweep chose with `protection`, as asked
    /// for and queues them, each with what `turn` (the history now) says
    /// it was.
    mutating func ask(
        _ turnIDs: [String],
        in directory: URL,
        sweptWith protection: TurnProtection,
        turn: (TurnID) -> TurnSummary?
    ) {
        var spans: [String: Span] = [:]
        for turnID in turnIDs {
            spans[turnID] = turn(TurnID(turnID)).flatMap(Span.of)
        }
        asked(turnIDs, spans: spans) { turn(TurnID($0))?.conversation }
        queue(turnIDs, in: directory, sweptWith: protection)
    }

    /// Notes a batch the sweep chose with `protection`, behind the ones
    /// already waiting.
    mutating func queue(_ turnIDs: [String], in directory: URL, sweptWith protection: TurnProtection) {
        waiting.append(Batch(directory: directory, turnIDs: turnIDs, sweptWith: protection))
    }

    /// The next batch to send, given what protects turns now. A batch the
    /// sweep chose while less was protected is dropped whole rather than
    /// trimmed: which turns may go is the sweep's to say (an unread turn
    /// still goes past the count limits, and no later turn of a worktree
    /// goes while an earlier one is held), so a pass sweeps again. Its turns
    /// are no longer on their way and wait for nothing. The pass that chose
    /// a batch may itself have reported turns that are protected (a turn
    /// just finished and unread); its batch then goes with the next pass,
    /// which sweeps with them. With no protection
    /// known, every batch is dropped, as the sweep itself waits.
    mutating func nextBatch(protection: TurnProtection?) -> Next {
        var next = Next()
        while hasBatchToSend {
            let batch = waiting.removeFirst()
            if let protection, protection.isCovered(by: batch.sweptWith) {
                isSending = true
                sending = batch
                // Before the batch goes: once a record is moved aside, a
                // quit may cut off its report.
                save()
                next.batch = batch
                return next
            }
            for turnID in batch.turnIDs {
                inFlight.remove(turnID)
                conversations.removeValue(forKey: turnID)
                spans.removeValue(forKey: turnID)
            }
            next.needsSweep = next.needsSweep || protection != nil
        }
        return next
    }

    /// What a finished batch of `asked` came to. Every turn asked for and not
    /// reported gone waits before it is asked for again: a refusal, a record
    /// this build may not delete (unchanged on disk, so never read again and
    /// chosen every pass), and a batch the bridge refused whole. A turn of a
    /// deletion an earlier run left cut short, which every batch finishes
    /// first, is reported gone too, with what the file kept of it, if
    /// anything.
    mutating func finished(asked: [String], _ deletions: [TurnDeletion], now: Date) -> Report {
        var report = Report(gone: [:], remaining: [])
        for deletion in deletions where deletion.isGone {
            noteGone(deletion.turnID, in: &report)
        }
        isSending = false
        sending = nil
        let retryAt = now.addingTimeInterval(Self.retryDelay)
        var remaining: Set<ConversationKey> = []
        for turnID in asked {
            inFlight.remove(turnID)
            spans.removeValue(forKey: turnID)
            let conversation = conversations.removeValue(forKey: turnID)
            if !report.gone.keys.contains(TurnID(turnID)) {
                retryAfter[turnID] = retryAt
                if let conversation {
                    remaining.insert(conversation)
                }
            }
        }
        save()
        report.remaining = remaining
        return completed(report)
    }

    /// Lets go of the spans of `turnIDs`, which the host has saved: the
    /// file no longer needs them.
    mutating func spansSaved(_ turnIDs: [String]) {
        var isChanged = false
        for turnID in turnIDs where unsaved.removeValue(forKey: turnID) != nil {
            isChanged = true
        }
        if isChanged {
            save()
        }
    }

    /// What the launch's own batch, which only finishes the deletions an
    /// earlier run left cut short, came to (`TurnGarbageCollector.enqueue`
    /// with no turns). Each turn the file kept is reported with what it
    /// was, and so is one of them that finished before the quit but was
    /// never heard of: its record is gone from its directory, aside or not
    /// (`recordState`). One whose record is back where it was was not
    /// deleted, and the next sweep decides afresh; one still aside waits
    /// for the next batch, which finishes it first.
    mutating func recovered(
        _ deletions: [TurnDeletion],
        recordState: (TurnDeletionEntry) -> TurnDeletionFile.RecordState
    ) -> Report {
        var report = Report(gone: [:], remaining: [])
        for deletion in deletions where deletion.isGone {
            noteGone(deletion.turnID, in: &report)
        }
        for (turnID, entry) in unheard where !inFlight.contains(turnID) {
            switch recordState(entry) {
            case .gone:
                noteGone(turnID, in: &report)
            case .present:
                unheard.removeValue(forKey: turnID)
            case .aside:
                continue
            }
        }
        save()
        return completed(report)
    }

    /// Adds `turnID` to the turns `report` says are gone, with what this
    /// run asked it for, or else what an earlier run kept in the file,
    /// which then keeps only its span, until the host has saved it. A turn
    /// not gone stays in the file: one put back is dropped by the next
    /// launch, which finds its record there.
    private mutating func noteGone(_ turnID: String, in report: inout Report) {
        let kept = unheard.removeValue(forKey: turnID)
        report.gone[TurnID(turnID)] = .some(conversations[turnID] ?? kept?.conversation)
        guard let span = spans[turnID] ?? kept?.span else { return }
        report.deletedIn[span.root, default: []].append(span.interval)
        report.spanTurnIDs.append(turnID)
        if let directory = kept?.directory ?? sending?.directory.path {
            unsaved[turnID] = TurnDeletionEntry(turnID: turnID, directory: directory, conversation: nil, span: span)
        }
    }

    /// `report` with the conversations no deletion may yet call empty.
    private func completed(_ report: Report) -> Report {
        var report = report
        report.remaining.formUnion(inFlight.compactMap { conversations[$0] })
        // A history built from part of the records may lack a conversation
        // that still has turns: none is called empty until it is whole.
        if !isHistoryComplete {
            report.remaining.formUnion(report.gone.values.compactMap(\.self))
        }
        return report
    }

    /// Writes the batch with the collector, the turns an earlier run
    /// left unheard, and the spans not saved yet to the file, each with
    /// what it was.
    private func save() {
        guard let url else { return }
        var entries = unheard.merging(unsaved) { kept, _ in kept }
        if let sending {
            for turnID in sending.turnIDs {
                entries[turnID] = TurnDeletionEntry(
                    turnID: turnID,
                    directory: sending.directory.path,
                    conversation: conversations[turnID],
                    span: spans[turnID]
                )
            }
        }
        TurnDeletionFile.write(entries.values.sorted { $0.turnID < $1.turnID }, to: url)
    }
}

private extension TurnProtection {
    /// Whether this protects nothing `earlier` did not.
    func isCovered(by earlier: TurnProtection) -> Bool {
        protectedTurnIDs.isSubset(of: earlier.protectedTurnIDs)
            && heldTurnIDs.isSubset(of: earlier.heldTurnIDs)
            && shownConversations.isSubset(of: earlier.shownConversations)
    }
}
