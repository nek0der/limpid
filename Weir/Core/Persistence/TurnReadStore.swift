// TurnReadStore.swift
// Weir — the turns the person has read, kept across launches in turn-reads.json.

import Foundation
import Observation
import OSLog
import WeirDomain

private let log = Logger.weir("turn.reads")

/// The turns read by having their pane in sight (`TurnReadRules`), by turn
/// ID, so a turn that answered without changing files stays read after a
/// relaunch. A turn that changed files is read by the viewed line instead,
/// which this store does not hold.
///
/// Its own file rather than the notification history: not every turn is
/// announced, and the history keeps 500 rows.
///
/// A mark holds the end the turn had when it was read. The hook takes a
/// turn's end again, under the same ID, when the agent goes on working
/// after its stop; a turn read for answering without changes may then have
/// changed files, which nobody has seen. Such a mark no longer counts, and
/// the turn is read again by the same rules as any other.
@MainActor
@Observable
final class TurnReadStore {
    /// What the file holds.
    private struct Document: Codable {
        static let currentVersion = 1
        var schemaVersion = Self.currentVersion
        /// Turn ID to when it was read.
        var reads: [String: Date] = [:]
        /// Turn ID to the end the turn had when it was read. Absent in a
        /// file from before it was kept, and dropped by an older build: a
        /// mark without one stands for whatever end the turn has, as it did
        /// then, until the turn is read again.
        var ends: [String: ReadEnd]?
    }

    /// The end a turn had when it was read: its end tree, `nil` when its end
    /// snapshot was not taken.
    struct ReadEnd: Codable, Equatable, Sendable {
        var tree: String?
    }

    /// One turn read, as it ended then.
    struct Mark: Hashable, Sendable {
        let turnID: TurnID
        let endTree: String?

        init(turnID: TurnID, endTree: String?) {
            self.turnID = turnID
            self.endTree = endTree
        }

        init(_ turn: TurnSummary) {
            self.init(turnID: turn.turnID, endTree: turn.endTree?.tree)
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

    /// Turn ID to when it was read. Marks are never aged out: a turn whose
    /// record is kept (the newest of a conversation, one under review) must
    /// stay read for as long as it is shown. They go with their records,
    /// through `forget(_:)`.
    private(set) var reads: [String: Date] = [:]
    /// Turn ID to the end it was read at; a mark without one is from a file
    /// that did not keep it.
    private(set) var ends: [String: ReadEnd] = [:]
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let saveDebounce = DebouncedSave()
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "com.nekoder.weir.turn-reads")
    /// False in demo mode: reads are kept in memory only, and the person's
    /// own file is neither read nor written.
    @ObservationIgnored private let writesFiles: Bool
    /// False after finding a newer build's file: its marks count here when
    /// they can be read, but rewriting it in this version's shape could drop
    /// what it added.
    @ObservationIgnored private var isWritable = true
    /// The clock for the read times; injected by tests.
    @ObservationIgnored private let now: () -> Date

    convenience init(writesFiles: Bool) {
        self.init(directory: WeirPaths.applicationSupportDirectory(), writesFiles: writesFiles)
    }

    init(directory: URL, writesFiles: Bool = true, now: @escaping () -> Date = Date.init) {
        self.writesFiles = writesFiles
        self.now = now
        self.fileURL = directory.appendingPathComponent("turn-reads.json")
        if writesFiles {
            SecureFileWrite.ensureUserOnlyDirectory(directory)
            load()
        }
    }

    /// Whether `turn` is read as it ends now.
    func isRead(_ turn: TurnSummary) -> Bool {
        isRead(Mark(turn))
    }

    /// Whether the turn is read at the end `mark` names: it was marked, and
    /// at that end, or by a file that did not keep the end.
    func isRead(_ mark: Mark) -> Bool {
        guard reads[mark.turnID.rawValue] != nil else { return false }
        return ends[mark.turnID.rawValue].map { $0.tree == mark.endTree } ?? true
    }

    /// Marks the turns read as they ended. Saved shortly after, together
    /// with any marks made in the meantime. A turn already read at that end
    /// keeps when it was first read; one read at another end is read anew.
    func markRead(_ marks: some Sequence<Mark>) {
        var isChanged = false
        let stamp = now()
        for mark in marks {
            let key = mark.turnID.rawValue
            let end = ReadEnd(tree: mark.endTree)
            if ends[key] == end, reads[key] != nil {
                continue
            }
            // A mark from a file that did not keep its end is given the
            // end it is read at now, and keeps its time.
            if reads[key] == nil || ends[key] != nil {
                reads[key] = stamp
            }
            ends[key] = end
            isChanged = true
        }
        // Nothing written unless something is new: this is asked on every
        // projection pass and every change of what is in sight, and each
        // write schedules a save (and redraws the list).
        guard isChanged else { return }
        scheduleSave()
    }

    /// Drops the marks of turns whose records were deleted (the retention
    /// sweep), so a mark lasts exactly as long as its turn.
    func forget(_ turns: some Sequence<TurnID>) {
        let gone = turns.map(\.rawValue).filter { reads[$0] != nil }
        guard !gone.isEmpty else { return }
        for turn in gone {
            reads[turn] = nil
            ends[turn] = nil
        }
        scheduleSave()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            if case .newer = try Self.migrator.migrate(data) {
                // Read for its marks, which only ever mean "read", and left
                // as it is.
                isWritable = false
            }
            let document = try PersistenceCoders.makeDecoder().decode(Document.self, from: data)
            reads = document.reads
            ends = document.ends ?? [:]
        } catch {
            // Unreadable marks cost a re-read of turns already read, never
            // a turn shown as read that was not, so they are dropped.
            log.error("turn reads unreadable: \(String(describing: error), privacy: .private)")
        }
    }

    private func scheduleSave() {
        guard writesFiles, isWritable else { return }
        let document = Document(reads: reads, ends: ends)
        let url = fileURL
        // The delay runs on the main queue; only the write itself goes to
        // the save queue, as in the other stores.
        saveDebounce.schedule { [saveQueue] in
            saveQueue.async {
                Self.write(document, to: url)
            }
        }
    }

    /// Writes on the save queue; a value-typed document, so nothing on the
    /// main actor is touched.
    private nonisolated static func write(_ document: Document, to url: URL) {
        do {
            let data = try PersistenceCoders.makeEncoder().encode(document)
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("write turn reads: \(String(describing: error), privacy: .private)")
        }
    }

    /// Writes any pending save now, for quitting and for tests. On the save
    /// queue, so a write already under way there cannot land after this one
    /// with older marks.
    func flushSynchronously() {
        guard writesFiles, isWritable, saveDebounce.hasPending else { return }
        saveDebounce.cancel()
        let document = Document(reads: reads, ends: ends)
        let url = fileURL
        saveQueue.sync {
            Self.write(document, to: url)
        }
    }
}
