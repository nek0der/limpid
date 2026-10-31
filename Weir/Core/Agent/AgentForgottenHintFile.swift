// AgentForgottenHintFile.swift
// Weir — keeps the ended sessions' hints still to delete across a relaunch, in ended-session-hints.json.

import Foundation
import OSLog

/// The hints the person ended a session by that are still on disk
/// (`AgentProjectionAdapter.forgottenHints`), kept between launches.
///
/// Only the person knows they moved on from a conversation, so nothing on
/// disk can tell it again at the next launch: the hint still names the
/// session, and the launch rules would resume it. A quit waits a moment
/// for a hook holding a hint's lock, and no longer; what is left is
/// written here and tried again, and kept from the rules, by the next
/// launch. The file is gone while nothing waits.
enum AgentForgottenHintFile {
    static let fileName = "ended-session-hints.json"
    static let schemaVersion = 1

    private static let file = VersionedListFile<EndedSessionHintsDocument>(
        schemaVersion: schemaVersion,
        label: "ended session hints",
        log: Logger.weir("agent.projection.forgotten")
    )

    /// The hints `url` holds. A file that is missing, does not read, or
    /// comes from a newer build holds none: what it loses is a session
    /// that may be offered again, which the person can end again.
    static func read(_ url: URL) -> [AgentForgottenHint] {
        file.read(url)
    }

    /// Writes `hints` to `url`, or removes the file when there are none.
    /// Returns whether the file now holds them, so a caller can try a
    /// failed write again though the hints have not changed since.
    @discardableResult
    static func write(_ hints: [AgentForgottenHint], to url: URL) -> Bool {
        file.write(hints, to: url)
    }
}

/// The hints still to delete (`AgentProjectionAdapter.forgottenHints`) and
/// their file, written as they change.
struct AgentForgottenHintQueue {
    /// Where the hints are kept between launches; `nil` keeps them in
    /// memory only, as a run that writes no files does.
    let url: URL?
    private(set) var hints: [AgentForgottenHint]
    /// Whether `url` does not hold `hints` yet: the last write failed, in a
    /// folder that would not take it, say. Kept because the hints need not
    /// change again before the next launch reads the file, so a write that
    /// waited for a change would never come.
    private var isUnsaved = false

    init(url: URL?) {
        self.url = url
        hints = url.map(AgentForgottenHintFile.read) ?? []
    }

    mutating func add(_ hint: AgentForgottenHint) {
        guard !hints.contains(hint) else { return }
        hints.append(hint)
        isUnsaved = true
        save()
    }

    mutating func removeAll(where shouldRemove: (AgentForgottenHint) -> Bool) {
        let count = hints.count
        hints.removeAll(where: shouldRemove)
        guard hints.count != count else { return }
        isUnsaved = true
        save()
    }

    /// Writes the hints when the file does not hold them yet.
    mutating func save() {
        guard isUnsaved, let url else { return }
        isUnsaved = !AgentForgottenHintFile.write(hints, to: url)
    }
}

/// What `AgentForgottenHintFile` holds on disk, under the key it has always been written with.
private struct EndedSessionHintsDocument: VersionedListDocument {
    var schemaVersion: Int
    var elements: [AgentForgottenHint]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case elements = "hints"
    }
}
