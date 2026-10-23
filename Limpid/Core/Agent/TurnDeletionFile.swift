// TurnDeletionFile.swift
// Limpid — keeps what the turns on their way to deletion were across a relaunch, in turn-deletions.json.

import Foundation
import OSLog

private let log = Logger.limpid("turn.gc")

/// One turn on its way, as `TurnDeletionFile` keeps it.
struct TurnDeletionEntry: Codable, Equatable, Sendable {
    let turnID: String
    /// The turns directory it is deleted from.
    let directory: String
    let conversation: ConversationKey?
    let span: TurnDeletionQueue.Span?

    private enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
        case directory
        case conversation
        case span
    }
}

/// The turns a batch has handed the collector and not heard back about
/// (`TurnDeletionQueue`), each with its conversation and when it ran, kept
/// between launches.
///
/// A deletion a quit cuts short leaves its record moved aside, and the next
/// launch finishes it before any pass has read the records: no history
/// then knows the turn. Without this file, its conversation and its span
/// would be lost, and what the turn changed would count as changed outside
/// turns once a gap opened there. Written before the batch goes
/// and emptied as it reports, so the file names only deletions that may
/// have happened unheard, and the turns gone whose spans are not saved
/// yet (`TurnDeletionQueue.spansSaved`). The file is gone while nothing
/// is on its way and every gone turn's span is saved.
enum TurnDeletionFile {
    static let fileName = "turn-deletions.json"
    static let schemaVersion = 1

    /// What became of a turn whose report a quit cut off, as its directory
    /// shows now.
    enum RecordState: Equatable {
        /// Its record is where it was: not deleted, and the next sweep
        /// decides afresh.
        case present
        /// Moved aside and not finished yet: still on its way.
        case aside
        /// Neither: the deletion finished unheard.
        case gone
    }

    private static let file = VersionedListFile<TurnDeletionsDocument>(
        schemaVersion: schemaVersion,
        label: "turn deletions on their way",
        log: log
    )

    /// The entries `url` holds. A file that is missing, does not read, or
    /// comes from a newer build holds none: what it loses is the span of a
    /// turn deleted unheard.
    static func read(_ url: URL) -> [TurnDeletionEntry] {
        file.read(url)
    }

    /// Writes `entries` to `url`, or removes the file when there are none.
    /// A write that fails is only logged: what it loses is what the file
    /// exists to keep, and the next change writes the whole list again.
    static func write(_ entries: [TurnDeletionEntry], to url: URL) {
        file.write(entries, to: url)
    }

    /// How `TurnDeletionQueue.recovered` judges the entries after the
    /// launch's batch for the turns directory `directory`: an entry of
    /// another directory is left for that directory's batch, as is every
    /// entry when this build reads no record layout.
    static func recordStates(in directory: URL) -> (TurnDeletionEntry) -> RecordState {
        let suffix = AgentProviderRegistry.recordLayout?.turnRecordSuffix
        return { entry in
            guard entry.directory == directory.path, let suffix else { return .aside }
            return recordState(of: entry.turnID, in: entry.directory, suffix: suffix)
        }
    }

    /// Where `turnID`'s record is in `directory`, by the names the bridge
    /// gives it (`turn_gc.rs`): `<id><suffix>`, and `.<id><suffix>.deleting`
    /// while its refs go.
    static func recordState(of turnID: String, in directory: String, suffix: String) -> RecordState {
        let directory = URL(fileURLWithPath: directory, isDirectory: true)
        let record = turnID + suffix
        let exists = { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        if exists(record) {
            return .present
        }
        return exists(".\(record).deleting") ? .aside : .gone
    }
}

/// What `TurnDeletionFile` holds on disk, under the key it has always been written with.
private struct TurnDeletionsDocument: VersionedListDocument {
    var schemaVersion: Int
    var elements: [TurnDeletionEntry]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case elements = "turns"
    }
}
