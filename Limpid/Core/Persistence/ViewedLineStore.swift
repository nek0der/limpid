// ViewedLineStore.swift
// Limpid — every conversation's viewed line, what was viewed outside turns, and restores' line moves, in viewed-lines.json.

import Foundation
import Observation
import OSLog

private let log = Logger.limpid("viewed.lines")

/// The viewed line of each conversation, by conversation, so a
/// conversation resumed in a new run keeps its line. One file for every
/// repository: a line is one small entry per conversation, and the turn
/// summaries this is fed do not say which repository a conversation is in
/// until a turn ends with a snapshot.
///
/// Each move also moves the conversation's auxiliary ref
/// (`ViewedLineRefs`), which this store never reads back.
///
/// The changes made outside every turn have no line: what was viewed of
/// them is each path's contents when it was viewed, by worktree
/// (`ReviewGit.contentFingerprints`), and a path whose contents differ now
/// is unviewed again. Kept beside the lines, so one Undo takes
/// back both.
@MainActor
@Observable
final class ViewedLineStore {
    /// What the file holds.
    private struct Document: Codable {
        static let currentVersion = 1
        var schemaVersion = Self.currentVersion
        var lines: [ViewedLine] = []
        /// By worktree top level, then by path. Absent in a file from
        /// before it was kept, which an older build reads and, rewriting,
        /// drops: the changes read as unviewed again, never the reverse.
        var outsideTurns: [String: [String: String]]?
        /// Absent in a file from before it was kept, and dropped by an
        /// older build: a gap a deleted turn of another conversation fell
        /// in then counts as changed outside turns again, as it did before.
        var deletedTurns: [String: [DateInterval]]?
        /// Absent in a file from before it was kept, and dropped by an
        /// older build: "Undo Restore" then leaves the line where it is, as
        /// it did after a relaunch before.
        var restoreMoves: [RestoreMoves]?
    }

    /// The line moves one restore made.
    private struct RestoreMoves: Codable {
        let opID: String
        /// The worktree the restore's journal is in, as git names it.
        /// Optional because an entry from an earlier development build has
        /// none: such an entry goes only when a reading lists its journal
        /// as one that can no longer be undone, never for its absence.
        let root: String?
        /// Read by nothing any more, but still written: a build that drops
        /// an entry by its age needs it to decode the file at all.
        let at: Date
        let moves: [ViewedLineUndo]

        /// The moves still in their line's history, which an undo can
        /// still take back; `nil` when none is.
        func live(in lines: [ConversationKey: ViewedLine]) -> Self? {
            let kept = moves.filter { move in
                lines[move.conversation]?.history.contains { $0.id == move.changeID } ?? false
            }
            return kept.isEmpty ? nil : Self(opID: opID, root: root, at: at, moves: kept)
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

    private(set) var lines: [ConversationKey: ViewedLine] = [:]
    /// What was viewed of the changes outside turns, by worktree top level:
    /// each path's contents then.
    private(set) var outsideTurns: [String: [String: String]] = [:]
    /// When the turns the retention sweep deleted ran, by the worktree
    /// their snapshots were taken in, merged where they meet: the changes
    /// outside turns leave out the gaps they fell in
    /// (`OutsideTurnsPlan.make`). Beside the marks of those changes, which
    /// it serves; not something Undo takes back.
    private(set) var deletedTurns: [String: [DateInterval]] = [:]
    /// How many spans a worktree keeps; past it the earliest two are joined
    /// into one, which leaves out more gaps, never fewer.
    static let deletedSpanLimit = 256
    /// What each mark replaced, by the change it was made with, for Undo.
    /// This run's only: a line's moves are kept across launches, so after a
    /// relaunch an "Unmark" on the changes panel takes back the line alone.
    @ObservationIgnored private var outsideTurnsBefore: [UUID: OutsideTurnsMark] = [:]
    /// By operation (`noteRestoreMoves`).
    @ObservationIgnored private var restoreMoves: [String: RestoreMoves] = [:]
    @ObservationIgnored private var outsideTurnsMarks = 0
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let saveDebounce = DebouncedSave()
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "dev.limpid.viewed-lines")
    /// False in demo mode: lines are kept in memory only, and neither the
    /// person's file nor their repositories' refs are touched.
    @ObservationIgnored private let writesFiles: Bool
    /// False after finding a newer build's file. Its lines count here when
    /// they can be read, but rewriting it in this version's shape could drop
    /// what it added.
    @ObservationIgnored private var isWritable = true
    /// `nil` when the refs are not written (demo mode, most tests).
    @ObservationIgnored private let refs: (any ViewedLineRefWriting)?
    @ObservationIgnored private let now: () -> Date

    convenience init(writesFiles: Bool) {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory(),
            writesFiles: writesFiles,
            refs: writesFiles ? ViewedLineRefs() : nil
        )
    }

    init(
        directory: URL,
        writesFiles: Bool = true,
        refs: (any ViewedLineRefWriting)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.writesFiles = writesFiles
        // A run that may not write the person's files does not touch their
        // repositories either, whatever it is handed.
        self.refs = writesFiles ? refs : nil
        self.now = now
        self.fileURL = directory.appendingPathComponent("viewed-lines.json")
        if writesFiles {
            SecureFileWrite.ensureUserOnlyDirectory(directory)
            load()
        }
    }

    func line(of conversation: ConversationKey) -> ViewedLine? {
        lines[conversation]
    }

    /// Whether `turn` is at or above its conversation's line.
    func isViewed(_ turn: TurnSummary) -> Bool {
        lines[turn.conversation]?.isViewed(turn) ?? false
    }

    /// Moves `turn`'s conversation's line below it. `nil` when the turn is
    /// already viewed, so there is nothing to undo.
    @discardableResult
    func markViewed(through turn: TurnSummary, source: ViewedLineSource) -> ViewedLineChange? {
        markViewed(through: [turn], source: source).first?.change
    }

    /// One conversation's move within a mark of several (`markViewed(through:source:)`).
    struct Move: Equatable, Sendable {
        let conversation: ConversationKey
        let change: ViewedLineChange

        /// What takes the move back.
        var undo: ViewedLineUndo {
            ViewedLineUndo(conversation: conversation, changeID: change.id)
        }
    }

    /// Moves each turn's conversation's line below it, as one mark: every
    /// move carries the same `markID`, which is what tells the moves of
    /// one mark from those of another, before a relaunch and after it
    /// ("Mark as Viewed up to Here" on the worktree's timeline moves every
    /// conversation's line). A turn already viewed moves nothing, and
    /// is left out of the moves.
    @discardableResult
    func markViewed(through turns: [TurnSummary], source: ViewedLineSource) -> [Move] {
        let at = now()
        let markID = UUID()
        let sequence = nextSequence()
        let kept = keptRestoreChanges()
        return turns.compactMap { turn in
            var line = lines[turn.conversation] ?? ViewedLine(conversation: turn.conversation)
            guard let change = line.advance(
                to: ViewedLinePosition(turn),
                source: source,
                markID: markID,
                sequence: sequence,
                at: at,
                keeping: kept
            ) else { return nil }
            commit(line, change: change)
            return Move(conversation: turn.conversation, change: change)
        }
    }

    /// Moves the line back above `turn`, so it and every later turn read as
    /// not viewed. `turns` is the conversation's turns, for the one before.
    @discardableResult
    func markNotViewed(from turn: TurnSummary, turns: [TurnSummary], source: ViewedLineSource) -> ViewedLineChange? {
        markNotViewed(from: [turn], history: [turn.conversation: turns], source: source).first?.change
    }

    /// Moves each turn's conversation's line back above it, as one mark,
    /// the mirror of `markViewed(through:source:)`: every move carries the
    /// same `markID`, so one Undo takes them all back ("Mark as Unviewed
    /// from Here" on the worktree's timeline moves every conversation's
    /// line). `history` is each conversation's turns, for the one
    /// before. A turn already unviewed moves nothing.
    @discardableResult
    func markNotViewed(
        from turns: [TurnSummary],
        history: [ConversationKey: [TurnSummary]],
        source: ViewedLineSource
    ) -> [Move] {
        let at = now()
        let markID = UUID()
        let sequence = nextSequence()
        let kept = keptRestoreChanges()
        return turns.compactMap { turn in
            guard var line = lines[turn.conversation] else { return nil }
            let earlier = (history[turn.conversation] ?? []).last { $0.displayNumber < turn.displayNumber }.map(ViewedLinePosition.init)
            guard let change = line.retreat(
                toBefore: ViewedLinePosition(turn),
                earlier: earlier,
                source: source,
                markID: markID,
                sequence: sequence,
                at: at,
                keeping: kept
            ) else { return nil }
            commit(line, change: change)
            return Move(conversation: turn.conversation, change: change)
        }
    }

    /// Records the changes outside turns in `root` as viewed with the
    /// contents they have in `fingerprints`, as part of the change
    /// `changeID`, whose Undo takes this back too. Paths not given are no
    /// longer viewed: they are no longer outside turns, and should one come
    /// back it is news.
    func markOutsideTurnsViewed(_ fingerprints: [String: String], in root: String, with changeID: UUID) {
        outsideTurnsMarks += 1
        outsideTurnsBefore[changeID] = OutsideTurnsMark(root: root, replaced: outsideTurns[root], order: outsideTurnsMarks)
        outsideTurns[root] = fingerprints
        scheduleSave()
    }

    /// Takes back the move `changeID` of `conversation` when it is still the
    /// latest, and what it marked viewed outside turns when that is. Each
    /// half stands alone: a later move of the line, or a later mark of the
    /// worktree, keeps that half, and the other is still taken back. False
    /// when neither was, or it was already taken back.
    @discardableResult
    func undo(_ changeID: UUID, in conversation: ConversationKey) -> Bool {
        let isOutsideUndone = undoOutsideTurns(changeID)
        guard var line = lines[conversation], let undone = line.undo(changeID) else {
            if isOutsideUndone {
                scheduleSave()
            }
            return isOutsideUndone
        }
        lines[conversation] = line
        refs?.move(conversation, from: undone.to?.endTree, to: undone.from?.endTree)
        scheduleSave()
        return true
    }

    /// Takes back what the mark `changeID` marked viewed outside turns,
    /// when no later mark of the worktree stands over it: a mark made with
    /// no conversation, so no line moved with it. False when it was not.
    @discardableResult
    func undoOutsideTurnsMark(_ changeID: UUID) -> Bool {
        let isUndone = undoOutsideTurns(changeID)
        if isUndone {
            scheduleSave()
        }
        return isUndone
    }

    /// The moves of the viewed line each applied restore made, by its
    /// operation, which "Undo Restore" takes back. Kept with the lines
    /// so an undo after a relaunch puts them back too; each is taken once.
    ///
    /// They live exactly as long as the restore's journal can be undone,
    /// which has no time limit (`may_expire` in `limpid-agent-hook`): a
    /// lifetime of their own, a clock or a count, would let "Undo Restore"
    /// put the code back and leave its turns read as viewed. So no clock
    /// drops them, and the line's history keeps them past its limit
    /// (`ViewedLine.trimHistory(keeping:)`), a restore superseded by a later
    /// turn too, as its journal stays. They go when a whole reading of the
    /// journals says the restore can no longer be undone, and are taken
    /// back when it says it was (`settleRestoreMoves`). They also go when
    /// their line can no longer take them back: taken back on their own
    /// ("Unmark as Viewed"), or gone with the line (`pruneRestoreMoves`).
    /// Before the undo, a move under later moves of its line stays: the
    /// later ones stand, and once they are unmarked the restore's is the
    /// latest again.
    func noteRestoreMoves(_ moves: [ViewedLineUndo], of opID: String, in root: String) {
        restoreMoves[opID] = moves.isEmpty ? nil : RestoreMoves(opID: opID, root: root, at: now(), moves: moves)
        scheduleSave()
    }

    /// The moves the restore `opID` made, once: its undo takes them back.
    func takeRestoreMoves(of opID: String) -> [ViewedLineUndo] {
        guard let taken = restoreMoves.removeValue(forKey: opID) else { return [] }
        scheduleSave()
        return taken.moves
    }

    /// Settles the moves of the restores a whole reading of a worktree's
    /// journals no longer lists as undoable. One it lists as undone has its
    /// moves taken back here, whichever undo did it: the record's, the
    /// launch toast's, or one whose end the app never heard (the bridge
    /// failed after writing, or the app quit). The record's undo ends with
    /// such a reading, so its own `takeRestoreMoves` then finds none,
    /// unless that reading was not whole. A move under a later move of its
    /// line is not taken back: the later one stands, and the entry goes all
    /// the same, as the restore is undone. One listed as aborted has its
    /// moves dropped. Any other stage keeps them: one still settling, or
    /// one this build cannot read, may yet be undone, and Rust holds only
    /// aborted and undone ones final. An entry of the worktree `isHere`
    /// names that the reading no longer lists is dropped too, while that
    /// worktree is there: Rust keeps an undoable restore's journal for good, and a
    /// worktree it could not find (a volume not mounted, a folder moved
    /// away) reads as one with no journal, whose restores come back with
    /// it. Only a whole reading is told: one that could not read some
    /// journals says nothing of the rest.
    func settleRestoreMoves(readOf isHere: (String) -> Bool, listing journals: [RestoreJournal]) {
        let listed = Dictionary(journals.map { ($0.opID, $0) }, uniquingKeysWith: { first, _ in first })
        var undone: [RestoreMoves] = []
        var ended: [RestoreMoves] = []
        for entry in restoreMoves.values {
            if let journal = listed[entry.opID] {
                if case .undone = journal.stage {
                    undone.append(entry)
                } else if case .aborted = journal.stage {
                    ended.append(entry)
                }
            } else if let root = entry.root, isHere(root), Self.isWorktreeThere(root) {
                ended.append(entry)
            }
        }
        guard !undone.isEmpty || !ended.isEmpty else { return }
        for entry in undone + ended {
            restoreMoves[entry.opID] = nil
        }
        for move in undone.flatMap(\.moves) {
            undo(move.changeID, in: move.conversation)
        }
        let kept = keptRestoreChanges()
        for conversation in Set(ended.flatMap(\.moves).map(\.conversation)) {
            lines[conversation]?.trimHistory(keeping: kept)
        }
        scheduleSave()
    }

    /// Whether the worktree at `root` is there for git to find: its
    /// folder, with the `.git` that makes it one.
    private static func isWorktreeThere(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent(".git").path)
    }

    /// The moves every restore still to be undone made, which the lines'
    /// histories keep past their limit.
    private func keptRestoreChanges() -> Set<UUID> {
        Set(restoreMoves.values.flatMap(\.moves).map(\.changeID))
    }

    /// Keeps `spans` and writes them at once, rather than with the next
    /// coalesced save: the deletion queue keeps them in its own file until
    /// this says they are saved (`TurnDeletionQueue.spansSaved`), and a
    /// deleted turn leaves no other record of when it ran. True once the
    /// file holds them, or at once for a store that writes no files (it
    /// keeps them in memory only); false when the file could not be
    /// written, or belongs to a newer build, so the queue keeps them for
    /// the next launch.
    func noteDeletedTurns(_ spans: [String: [DateInterval]]) async -> Bool {
        var merged = deletedTurns
        for (root, intervals) in spans {
            merged[root] = Self.merge((merged[root] ?? []) + intervals)
        }
        if merged != deletedTurns {
            deletedTurns = merged
        }
        // Spans already held may not be on disk yet, so we write them all the same.
        guard writesFiles else { return true }
        guard isWritable else { return false }
        pruneRestoreMoves()
        saveDebounce.cancel()
        let document = makeDocument()
        let url = fileURL
        return await withCheckedContinuation { continuation in
            saveQueue.async {
                continuation.resume(returning: Self.write(document, to: url))
            }
        }
    }

    /// Lets go of the spans of the worktrees `isRemoved` names, whose
    /// project or worktree the person removed. Only then: a worktree
    /// merely missing (a volume not mounted, a folder moved away) keeps
    /// its spans, which it needs again once it is back.
    func forgetDeletedTurns(where isRemoved: (String) -> Bool) {
        let kept = deletedTurns.filter { !isRemoved($0.key) }
        guard kept.count != deletedTurns.count else { return }
        deletedTurns = kept
        scheduleSave()
    }

    /// The spans of the turns deleted in the worktrees `isHere` says are
    /// the one asked about: the hook names a worktree by its top level,
    /// which may be spelled through a link (`RepositoryRoots.isRoot`).
    func deletedTurns(where isHere: (String) -> Bool) -> [DateInterval] {
        deletedTurns.filter { isHere($0.key) }.values.flatMap(\.self)
    }

    /// Sorted, joined where they meet, and kept within the limit.
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        while merged.count > deletedSpanLimit {
            let joined = DateInterval(start: merged[0].start, end: max(merged[0].end, merged[1].end))
            merged.replaceSubrange(0...1, with: [joined])
        }
        return merged
    }

    /// Puts back what the mark `changeID` replaced. Under a later mark of
    /// the same worktree, the later one stands and is made to replace what
    /// this one did: taking it back afterwards must not bring back a mark
    /// already taken back.
    private func undoOutsideTurns(_ changeID: UUID) -> Bool {
        guard let mark = outsideTurnsBefore.removeValue(forKey: changeID) else { return false }
        let next = outsideTurnsBefore
            .filter { $0.value.root == mark.root && $0.value.order > mark.order }
            .min { $0.value.order < $1.value.order }
        if let next {
            outsideTurnsBefore[next.key] = OutsideTurnsMark(root: mark.root, replaced: mark.replaced, order: next.value.order)
            return false
        }
        outsideTurns[mark.root] = mark.replaced
        return true
    }

    /// Drops the lines of conversations whose turns are all deleted (the
    /// retention sweep), with their refs.
    func forget(_ conversations: some Sequence<ConversationKey>) {
        var isChanged = false
        for conversation in conversations {
            guard let line = lines.removeValue(forKey: conversation) else { continue }
            refs?.move(conversation, from: line.position?.endTree, to: nil)
            isChanged = true
        }
        if isChanged {
            scheduleSave()
        }
    }

    /// One mark of the changes outside turns, for its Undo: what it
    /// replaced, and its place among this run's marks.
    private struct OutsideTurnsMark {
        let root: String
        let replaced: [String: String]?
        let order: Int
    }

    /// The next mark's place (`ViewedLineChange.sequence`): one past the
    /// latest any line kept, so it goes on from the file after a launch.
    private func nextSequence() -> Int {
        let latest = lines.values.flatMap(\.history).compactMap(\.sequence).max() ?? 0
        return latest + 1
    }

    private func commit(_ line: ViewedLine, change: ViewedLineChange) {
        lines[line.conversation] = line
        refs?.move(line.conversation, from: change.from?.endTree, to: change.to?.endTree)
        scheduleSave()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            if case .newer = try Self.migrator.migrate(data) {
                isWritable = false
            }
            let document = try PersistenceCoders.makeDecoder().decode(Document.self, from: data)
            lines = Dictionary(document.lines.map { ($0.conversation, $0) }, uniquingKeysWith: { first, _ in first })
            // A worktree since removed has nothing left to view. One on a
            // volume not mounted yet is dropped too, which only makes its
            // changes unviewed again.
            outsideTurns = (document.outsideTurns ?? [:]).filter { FileManager.default.fileExists(atPath: $0.key) }
            // We keep the deleted turns' spans all the same: dropped for a worktree not
            // mounted yet, they would be gone for good, and what those
            // turns changed would count as changed outside turns once it
            // is back. They go when the person removes the worktree
            // (`forgetDeletedTurns(where:)`).
            deletedTurns = document.deletedTurns ?? [:]
            restoreMoves = Dictionary(
                (document.restoreMoves ?? []).map { ($0.opID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            pruneRestoreMoves()
        } catch {
            // Unreadable lines put turns back to not viewed, which costs a
            // second look, never a turn shown as viewed that was not.
            log.error("viewed lines unreadable: \(String(describing: error), privacy: .private)")
        }
    }

    /// Drops the restore moves no line can take back any more
    /// (`noteRestoreMoves`): taken back on their own, or gone with their
    /// line. Nothing else takes a move out of a line's history while it is
    /// kept.
    private func pruneRestoreMoves() {
        restoreMoves = restoreMoves.compactMapValues { $0.live(in: lines) }
    }

    private func scheduleSave() {
        pruneRestoreMoves()
        guard writesFiles, isWritable else { return }
        let document = makeDocument()
        let url = fileURL
        // The delay runs on the main queue; only the write itself goes to
        // the save queue.
        saveDebounce.schedule { [saveQueue] in
            saveQueue.async {
                Self.write(document, to: url)
            }
        }
    }

    /// Sorted, so the same lines always write the same file.
    private func makeDocument() -> Document {
        Document(
            lines: lines.values.sorted { Self.order($0.conversation) < Self.order($1.conversation) },
            outsideTurns: outsideTurns.isEmpty ? nil : outsideTurns,
            deletedTurns: deletedTurns.isEmpty ? nil : deletedTurns,
            restoreMoves: restoreMoves.isEmpty ? nil : restoreMoves.values.sorted { $0.opID < $1.opID }
        )
    }

    private static func order(_ key: ConversationKey) -> String {
        "\(key.provider.rawValue)\n\(key.conversationID)\n\(key.isFallback)"
    }

    /// Whether the file now holds `document`.
    @discardableResult
    private nonisolated static func write(_ document: Document, to url: URL) -> Bool {
        do {
            let data = try PersistenceCoders.makeEncoder().encode(document)
            try SecureFileWrite.writeAtomic(data, to: url)
            return true
        } catch {
            log.error("write viewed lines: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// Writes any pending save now, and waits for the refs, for quitting
    /// and for tests.
    func flushSynchronously() {
        refs?.waitForPendingMoves()
        guard writesFiles, isWritable, saveDebounce.hasPending else { return }
        saveDebounce.cancel()
        let document = makeDocument()
        let url = fileURL
        saveQueue.sync {
            _ = Self.write(document, to: url)
        }
    }
}
