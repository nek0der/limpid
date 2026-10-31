// RestorePendingStopFile.swift
// Weir — keeps the launch notices of undos cut short whose operation could not be read yet, in restore-pending-stops.json.

import Foundation
import OSLog

private let log = Logger.weir("restore")

/// An undo that recovery settled after a crash cut it short, whose launch
/// notice waits for the restore or discard it was undoing to be read.
struct RestorePendingStop: Codable, Equatable, Sendable {
    /// The worktree, as git names it (the undo journal's `root`).
    let root: String
    /// The undo that recovery settled.
    let settledID: String
    /// The restore or discard the undo was taking back, which the notice's
    /// Undo takes back in turn.
    let undoableID: String
    /// When the undo was settled: past a journal's lifetime the operation
    /// is gone or final, and the notice goes with it. Rust counts from the
    /// journal's own `at`, a little earlier, so a notice may outlast its
    /// journal by a launch; the first whole reading without it drops it.
    let since: Date

    private enum CodingKeys: String, CodingKey {
        case root
        case settledID = "settledId"
        case undoableID = "undoableId"
        case since
    }
}

/// The launch notices of undos cut short whose operation's journal could
/// not be read when recovery settled the undo (`RestoreCoordinator`),
/// kept between launches.
///
/// Rust names an operation as settled only in the reading that settled it,
/// so without this file a notice whose operation stayed unreadable until
/// the app quit would never come. For a discard that notice is the only way
/// back, as its review closed with the app. Deriving the notice again from
/// the undo's journal on every reading would tell it at every launch; the
/// file tells it once. The file is gone while nothing waits.
enum RestorePendingStopFile {
    static let fileName = "restore-pending-stops.json"
    static let schemaVersion = 1
    /// How long a notice waits: Rust's journal lifetime
    /// (`JOURNAL_LIFETIME_SECS`). An undo cut short is final and goes after
    /// it, and a whole discard does too; a restore that stays has its own
    /// record with its Undo.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    private static let file = VersionedListFile<RestorePendingStopsDocument>(
        schemaVersion: schemaVersion,
        label: "restore notices waiting for their operation",
        log: log
    )

    /// The notices `url` holds. A file that is missing, does not read, or
    /// comes from a newer build holds none: what it loses is the launch
    /// notice of an undo cut short, whose restore still has its record.
    static func read(_ url: URL) -> [RestorePendingStop] {
        file.read(url)
    }

    /// Writes `stops` to `url`, or removes the file when there are none. A
    /// write that fails is only logged: the next change writes the whole
    /// list again. One that fails after a notice was told tells it again at
    /// the next launch, which we take over losing a discard's only Undo.
    static func write(_ stops: [RestorePendingStop], to url: URL) {
        file.write(stops, to: url)
    }
}

/// What `RestorePendingStopFile` holds on disk.
private struct RestorePendingStopsDocument: VersionedListDocument {
    var schemaVersion: Int
    var elements: [RestorePendingStop]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case elements = "stops"
    }
}
