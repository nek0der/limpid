// AgentSharedHelpers.swift
// Weir — small utilities the agent slice shares: the one ISO-8601
// formatter both sides of the projection boundary use, the session-id
// shape check the resume commands interpolate through, POSIX quoting,
// and the whole-session tab transform the projection applies its answer
// through.

import Foundation
import os

/// ISO-8601 parsing for the instants that cross the projection boundary.
/// The hook backends and the Rust rules both write UTC instants with whole
/// seconds (`2026-10-22T12:34:56Z`) that round-trip through this one
/// `ISO8601DateFormatter` instance.
enum AgentDateParsing {
    static func parseISO8601(_ string: String) -> Date? {
        formatter.withLockUnchecked { $0.date(from: string) }
    }

    static func parseOptional(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return parseISO8601(raw)
    }

    /// Inverse of `parseISO8601` — used to stamp the instants the
    /// projection input carries, such as the wall clock of one pass and
    /// the marker on a run Weir is about to kill at quit.
    static func formatISO8601(_ date: Date) -> String {
        formatter.withLockUnchecked { $0.string(from: date) }
    }

    /// The one formatter, behind a lock. Detached projection passes parse
    /// with it while the main actor stamps input instants, and Apple
    /// documents thread safety for `DateFormatter`, not for
    /// `ISO8601DateFormatter`, so we serialize every call rather than rely
    /// on an undocumented guarantee. The formatter never leaves the lock:
    /// each closure returns only a `Date` or a `String`.
    ///
    /// We keep the class over the Sendable `Date.ISO8601FormatStyle`
    /// because the style does not read and write the same: it accepts
    /// fractional seconds, which this boundary has always rejected, and it
    /// truncates a fraction where the formatter rounds it to the nearest
    /// second.
    private static let formatter: OSAllocatedUnfairLock<ISO8601DateFormatter> = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return OSAllocatedUnfairLock(uncheckedState: formatter)
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

    /// `isValid`, and starting with a letter or a digit as every session id
    /// does: typed into a shell, one starting with `-` would be read as an
    /// option of the CLI (`--dangerously-…`).
    static func isStrictlyValid(_ id: String) -> Bool {
        guard isValid(id), let first = id.unicodeScalars.first else { return false }
        return first != "-" && first != "_"
    }

    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
}

extension Unicode.Scalar {
    /// C0, DEL, and C1: what a line editor reads as keys rather than text,
    /// so a command typed into a terminal must not carry one. DEL is a
    /// backspace that could take a quote away from a path.
    var isTypedControl: Bool {
        value < 0x20 || (0x7F...0x9F).contains(value)
    }
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

// MARK: - WorkspaceSession helper

@MainActor
extension WorkspaceSession {
    /// Applies a mutating transform to every tab. The projection decides what
    /// each tab should hold and applies the whole answer at once, so the shape
    /// of the iteration does not belong at that call site.
    func applyAcrossTabs(_ transform: (inout Tab) -> Void) {
        for tab in tabs {
            update(tab.id, transform: transform)
        }
    }
}
