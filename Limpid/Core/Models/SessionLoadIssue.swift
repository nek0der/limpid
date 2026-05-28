// SessionLoadIssue.swift
// Limpid — one-line summary of why the persisted session couldn't be restored

import Foundation

enum SessionLoadIssue: Equatable, Identifiable {
    case versionMismatch(found: Int, expected: Int)
    case decodeFailed(message: String)

    var id: String {
        switch self {
        case let .versionMismatch(f, e): "vm:\(f)->\(e)"
        case let .decodeFailed(m): "df:\(m)"
        }
    }

    var title: String {
        switch self {
        case .versionMismatch: String(localized: "Previous session not restored")
        case .decodeFailed: String(localized: "Failed to restore previous session")
        }
    }

    var detail: String {
        switch self {
        case let .versionMismatch(found, expected):
            String(localized: "Saved session uses schema v\(found); Limpid expected v\(expected). A fresh window was opened instead.")
        case let .decodeFailed(message):
            message
        }
    }
}
