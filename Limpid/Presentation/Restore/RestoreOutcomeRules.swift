// RestoreOutcomeRules.swift
// Limpid — how a restore ended as the strip and the bar take it, and which turns a restore took back.

import Foundation

/// How a restore ended, as the app answers it.
enum RestoreEnding: Equatable {
    /// Every planned path holds the turn's start: the bar's "Done" line, a
    /// toast with Undo, and the record.
    case applied(RestoreJournal)
    /// Part of it is in the working tree: the strip says what stayed,
    /// what could not be written, and where a save made meanwhile was put,
    /// and the record offers Undo.
    case partial(RestoreJournal, kept: [String], failed: [String], keptAside: [RestoreKeptAside] = [])
    /// It wrote nothing, or nothing it wrote is left: the strip says why.
    case canceled(Reason)
    /// How it ended is not known: its journal was read before it settled
    /// or in a stage this build does not know (`opID`), or the bridge
    /// failed, perhaps after writing (`nil`). The coordinator read the
    /// worktree again after it ran, so the record of this operation shows
    /// what it holds, if anything; nothing may say no file was changed.
    case unknown(opID: String?)

    enum Reason: Equatable {
        case refused(RestoreRefusal)
        /// A planned path changed while the restore ran, by an editor or
        /// an agent that does not take the lock.
        case otherChanges
        /// Rust aborted for a reason this build does not name.
        case unknown
    }

    /// How a restore that is not in the working tree whole ended: what the
    /// strip says in its place (`RestoreText.ended`). Its own type, so the
    /// strip's sentence cannot be asked for a restore that has none.
    enum Shortfall: Equatable {
        case partial(kept: [String], failed: [String], keptAside: [RestoreKeptAside] = [])
        case canceled(Reason)
        case unknown
    }

    init(_ outcome: RestoreOutcome?) {
        guard let outcome else {
            self = .unknown(opID: nil)
            return
        }
        switch outcome {
        case let .refused(refusal):
            self = .canceled(.refused(refusal))
        case let .finished(journal):
            switch journal.stage {
            case _ where journal.stage.isWhole:
                // Saves moved aside or not, it is in the working tree whole.
                self = .applied(journal)
            case .applied:
                self = .applied(journal)
            case let .partiallyApplied(_, kept, failed, keptAside):
                self = .partial(journal, kept: kept, failed: failed, keptAside: keptAside)
            case let .aborted(reason):
                self = .canceled(Self.reason(aborted: reason))
            case .planned, .writing, .verifying, .undone, .unknown:
                self = .unknown(opID: journal.opID)
            }
        }
    }

    /// What an abort says, by its reason.
    private static func reason(aborted reason: RestoreStageReason) -> Reason {
        switch reason {
        case .externalChangeDetected: .otherChanges
        case .agentStarted: .refused(.agentStarted)
        case .writeFailed, .interrupted, .keptAside, .unknown: .unknown
        }
    }
}

/// What the launch toast says of the operations recovery settled.
enum RecoveryNews {
    /// The toast for `stops`: what the one of them was, or how many; `nil`
    /// when there is none.
    static func kind(_ stops: [RestoreCoordinator.RecoveredStop]) -> ToastKind? {
        guard let only = stops.first else { return nil }
        guard stops.count == 1 else { return .operationsInterrupted(count: stops.count) }
        let settled = only.settled
        if settled.undoes != nil {
            return .undoInterrupted
        }
        if settled.operation == .discard {
            return settled.stage.isInterrupted ? .discardInterrupted : .discardSettled
        }
        return .restoreInterrupted
    }
}

/// This holds every turn of every conversation, flattened once with its start
/// read as a date and its position kept by ID, so each journal a
/// computation asks about does not flatten and parse the whole history
/// again (`RestoredTurns.ids`).
struct RestoredTurnsIndex {
    struct Entry {
        let turn: TurnSummary
        let started: Date?
    }

    let entries: [Entry]
    /// This maps each turn ID to its first entry, as `first(where:)` would find it.
    let positions: [TurnID: Int]

    init(_ history: [ConversationKey: [TurnSummary]]) {
        entries = history.values.joined().map { Entry(turn: $0, started: UnreadTurnRules.date($0.startedAt)) }
        positions = Dictionary(
            entries.enumerated().map { ($1.turn.turnID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// Which turns a restore took back, and how long its record stands.
enum RestoredTurns {
    /// Every conversation's turns that began in the restore's worktree
    /// from the turn it went back to until it ran: their changes are gone
    /// from the working tree. Empty when the turn's own record is gone,
    /// as nothing then says where they start. `isRoot` says whether a root
    /// a snapshot names is the journal's worktree, which may be spelled
    /// through a link.
    static func of(
        _ journal: RestoreJournal,
        history: [ConversationKey: [TurnSummary]],
        isRoot: (String) -> Bool
    ) -> [TurnSummary] {
        of(journal, index: RestoredTurnsIndex(history), isRoot: isRoot)
    }

    /// Does the same, reading from an index built once for many journals.
    static func of(
        _ journal: RestoreJournal,
        index: RestoredTurnsIndex,
        isRoot: (String) -> Bool
    ) -> [TurnSummary] {
        guard let position = index.positions[journal.turnID],
              let from = index.entries[position].started
        else { return [] }
        let ran = UnreadTurnRules.date(journal.ranAt)
        return index.entries.compactMap { entry in
            guard let root = entry.turn.beginTree?.root, isRoot(root) else { return nil }
            if entry.turn.turnID == journal.turnID {
                return entry.turn
            }
            guard let started = entry.started else { return nil }
            return started >= from && !began(started, after: ran) ? entry.turn : nil
        }
    }

    /// Whether a turn that started at `started` began after the restore
    /// that ran at `ran`; with `ran` not known, none did. `ran` is
    /// `RestoreJournal.ranAt`, not `at`: a recovery that settles the
    /// restore after a crash writes its journal later, and a turn begun
    /// between the two began after the restore all the same. Both are kept
    /// to the second, so a turn and the restore can share one. Such a turn
    /// may have begun on either side of it, so we take the side whose
    /// mistake costs less: begun after. Read so, it
    /// still waits as unviewed rather than being hidden as taken back, and
    /// it ends the record rather than leaving an undo that would put back
    /// changes it never saw. The other way, a turn the person is
    /// working in would vanish from the lists and the record would never
    /// end. A turn's start time is taken once its hook holds the worktree
    /// lock a restore holds while it runs, so a prompt that arrived while
    /// the restore ran starts after it, and this settles only the shared
    /// second.
    /// `of` and `isSuperseded` both ask this, so a turn is never both
    /// restored and after the restore.
    static func began(_ started: Date, after ran: Date?) -> Bool {
        guard let ran else { return false }
        return started >= ran
    }

    /// The turns every restore not undone took back, in every worktree:
    /// what each list that reads a turn (the changes panel, the review's
    /// choices, the attention list, the decision bar) leaves out, so they
    /// agree. For as long as the restore stands, not only while
    /// its record shows: a turn begun after it ends the record
    /// (`isSuperseded`), not the fact that those changes are gone.
    /// Only a whole restore (`RestoreStage.isWhole`): one that left paths as
    /// another writer changed them, or could not write some, took nothing
    /// back whole, and its turns keep the changes it left, though its record
    /// shows to say so. `isRoot` gives, for a journal's root, whether a root
    /// a snapshot names is that worktree.
    static func ids(
        journals: [String: [RestoreJournal]],
        history: [ConversationKey: [TurnSummary]],
        isRoot: (String) -> (String) -> Bool
    ) -> Set<TurnID> {
        let standing = journals.values.joined().filter {
            $0.operation == .restore && $0.isUndoable && $0.stage.isWhole
        }
        guard !standing.isEmpty else { return [] }
        // We build one index for every journal: each one otherwise flattened
        // the whole history and parsed every start again.
        let index = RestoredTurnsIndex(history)
        return standing.reduce(into: []) { ids, journal in
            ids.formUnion(of(journal, index: index, isRoot: isRoot(journal.root)).map(\.turnID))
        }
    }

    /// Whether a turn began in the restore's worktree after it ran. The
    /// person has gone on from the restored code, and told the agent what
    /// they meant to, so the record ends: undoing it now would put back
    /// changes the new work never saw.
    static func isSuperseded(
        _ journal: RestoreJournal,
        history: [ConversationKey: [TurnSummary]],
        isRoot: (String) -> Bool
    ) -> Bool {
        guard let ran = UnreadTurnRules.date(journal.ranAt) else { return false }
        return history.values.contains { turns in
            turns.contains { turn in
                guard let root = turn.beginTree?.root, isRoot(root),
                      let started = UnreadTurnRules.date(turn.startedAt)
                else { return false }
                return began(started, after: ran)
            }
        }
    }
}

/// This holds the restored turns last worked out, with what they were worked out from.
/// The answer reads the whole history, so it is kept while none of its
/// sources moved: the history (by revision), the journals (an Undo, a new
/// restore, and the sweep each change them), and the path spellings.
struct RestoredTurnsMemo {
    struct Key: Equatable {
        let historyRevision: Int
        let journals: [String: [RestoreJournal]]
        let pathGeneration: Int
    }

    let key: Key
    let ids: Set<TurnID>

    /// Returns the answer for `key`: the kept one when it was worked out from the
    /// same sources, else `compute`'s, which is kept in its place.
    static func ids(
        for key: Key,
        kept: inout RestoredTurnsMemo?,
        compute: (Key) -> Set<TurnID>
    ) -> Set<TurnID> {
        if let kept, kept.key == key {
            return kept.ids
        }
        let ids = compute(key)
        kept = RestoredTurnsMemo(key: key, ids: ids)
        return ids
    }
}
