// VersionedListFile.swift
// Limpid — a small JSON file of one versioned list that is gone while the list is empty.

import Foundation
import OSLog

/// The shape of a `VersionedListFile` on disk: a version and one list. Each
/// file names its list's key itself (`hints`, `turns`) through its own
/// `CodingKeys`, so the files already written keep reading.
protocol VersionedListDocument: Codable {
    associatedtype Element: Codable
    var schemaVersion: Int { get }
    var elements: [Element] { get }
    init(schemaVersion: Int, elements: [Element])
}

/// Reads and writes a list that must outlive a relaunch but is not worth a
/// migration: the files that keep work still to finish
/// (`AgentForgottenHintFile`, `TurnDeletionFile`, `RestorePendingStopFile`).
///
/// One type for all of them, so how a missing, unreadable, or newer file reads,
/// and how an empty list removes the file, cannot drift between them.
struct VersionedListFile<Document: VersionedListDocument>: Sendable {
    let schemaVersion: Int
    /// What the list is, for the log (`ended session hints`).
    let label: String
    let log: Logger

    /// The elements `url` holds. A file that is missing, does not read, or
    /// comes from a newer build holds none: each caller's doc says what
    /// that loses, and why it is the safe answer.
    func read(_ url: URL) -> [Document.Element] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == schemaVersion
        else {
            log.error("\(label, privacy: .public) do not read; dropped")
            return []
        }
        return document.elements
    }

    /// Writes `elements` to `url`, or removes the file when there are none.
    /// Returns whether the file now holds them; a failure is logged here.
    @discardableResult
    func write(_ elements: [Document.Element], to url: URL) -> Bool {
        do {
            if elements.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try SecureFileWrite.removeItem(at: url)
                }
                return true
            }
            let data = try JSONEncoder().encode(Document(schemaVersion: schemaVersion, elements: elements))
            SecureFileWrite.ensureUserOnlyDirectory(url.deletingLastPathComponent())
            try SecureFileWrite.writeAtomic(data, to: url)
            return true
        } catch {
            let reason = error.localizedDescription
            log.error("\(label, privacy: .public) not saved: \(reason, privacy: .private)")
            return false
        }
    }
}
