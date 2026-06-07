// AgentSharedHelpers.swift
// Limpid — shared utilities lifted out of the per-flavor Claude /
// Codex agent files so the generic tracker / builder implementations
// don't have to thread them through. Each was previously duplicated
// across the twins; this file is the single source.

import Foundation

/// ISO-8601 parsing used by both `ClaudeAgent.makeBadge` and
/// `CodexAgent.makeBadge`. The hook scripts write `date -u
/// +"%Y-…%Z"` which round-trips cleanly through the same
/// `ISO8601DateFormatter` instance.
enum AgentDateParsing {
    static func parseISO8601(_ string: String) -> Date? {
        formatter.date(from: string)
    }

    static func parseOptional(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return parseISO8601(raw)
    }

    /// Inverse of `parseISO8601` — used by Codex's
    /// `preserveLiveSessionsOnTerminate` to stamp the
    /// `killedByLimpidAt` marker on app quit.
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
