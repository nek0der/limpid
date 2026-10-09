// SessionLoadIssue.swift
// Limpid — one-line summary of why the persisted session couldn't be restored

import Foundation

enum SessionLoadIssue: Equatable, Identifiable {
    case versionMismatch(found: Int, expected: Int)
    case decodeFailed(message: String)
    /// The snapshot loaded, but we dropped the tabs whose pane IDs collided
    /// or chose another sidebar item for the one that couldn't be restored.
    case recovered(droppedTabCount: Int, didResetActiveContainer: Bool)

    var id: String {
        switch self {
        case let .versionMismatch(f, e): "vm:\(f)->\(e)"
        case let .decodeFailed(m): "df:\(m)"
        case let .recovered(n, reset): "rc:\(n):\(reset)"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .versionMismatch: "Previous session not restored"
        case .decodeFailed: "Failed to restore previous session"
        case .recovered: "Previous session repaired"
        }
    }

    /// The decoder's own message is shown as is: it names the JSON path
    /// that failed, which no catalog string could carry.
    var detail: DisplayText {
        switch self {
        case let .versionMismatch(found, expected):
            .localized("Saved session uses schema v\(found); Limpid expected v\(expected). A fresh window was opened instead.")
        case let .decodeFailed(message):
            .verbatim(message)
        case let .recovered(droppedTabCount, didResetActiveContainer):
            .localized(Self.recoveryDetail(droppedTabCount: droppedTabCount, didResetActiveContainer: didResetActiveContainer))
        }
    }

    /// One whole sentence per combination, so a translation never depends
    /// on how we would join two of them.
    private static func recoveryDetail(droppedTabCount: Int, didResetActiveContainer: Bool) -> LocalizedStringResource {
        if droppedTabCount == 0 {
            return "The selected sidebar item could not be restored, so another one is selected."
        }
        if didResetActiveContainer {
            // swiftlint:disable:next line_length
            return "Removed \(droppedTabCount) tabs with duplicate pane IDs. The selected sidebar item could not be restored, so another one is selected."
        }
        return "Removed \(droppedTabCount) tabs with duplicate pane IDs."
    }
}
