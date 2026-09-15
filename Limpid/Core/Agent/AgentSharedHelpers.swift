// AgentSharedHelpers.swift
// Limpid — small utilities the agent slice shares: the one ISO-8601
// formatter both sides of the projection boundary use, the session-id
// shape check the resume commands interpolate through, POSIX quoting,
// and the whole-session tab transform the projection applies its answer
// through.

import Foundation

/// ISO-8601 parsing for the instants that cross the projection boundary.
/// The hook backends and the Rust rules both write UTC instants that
/// round-trip through this one `ISO8601DateFormatter` instance.
enum AgentDateParsing {
    static func parseISO8601(_ string: String) -> Date? {
        formatter.date(from: string)
    }

    static func parseOptional(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return parseISO8601(raw)
    }

    /// Inverse of `parseISO8601` — used to stamp the instants the
    /// projection input carries, such as the wall clock of one pass and
    /// the marker on a run Limpid is about to kill at quit.
    static func formatISO8601(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// `nonisolated(unsafe)` because `ISO8601DateFormatter` is not
    /// declared `Sendable` but Apple documents `date(from:)` as
    /// thread-safe once the instance is configured. The formatter is
    /// configured exactly once at file scope and only read after
    /// that, so the unchecked declaration matches reality.
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Validates that a session id is shell-safe (UUID-ish: hex + hyphens
/// + underscores). Both Claude and Codex emit ids in this shape; a
/// hand-edited `state.json` could otherwise smuggle shell
/// metacharacters into the resume command.
enum AgentSessionIDValidator {
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
}

/// POSIX single-quoting for paths embedded in resume shell commands.
/// The `'\''` dance is the standard way to escape an embedded `'`
/// within a single-quoted string — survives `cd …` without further
/// quoting from the caller.
enum ShellQuote {
    static func single(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - WindowSession helper

@MainActor
extension WindowSession {
    /// Applies a mutating transform to every tab. The projection decides what
    /// each tab should hold and applies the whole answer at once, so the shape
    /// of the iteration does not belong at that call site.
    func applyAcrossTabs(_ transform: (inout Tab) -> Void) {
        for tab in tabs {
            update(tab.id, transform: transform)
        }
    }
}
