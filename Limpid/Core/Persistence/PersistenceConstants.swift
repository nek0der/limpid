// PersistenceConstants.swift
// Limpid — named timings + a single JSON coder factory shared by
// every top-level Codable store. Per-store constants drift apart
// (debounce lengths, date strategies, pretty-printing); one place keeps
// the on-disk shape uniform and makes a timing or format change a
// one-line edit.

import Foundation

// MARK: - Debounce timings

/// Named write-debounce intervals. The numbers are tuned, not magical,
/// so changing them belongs here — not inline.
enum PersistenceTiming {
    /// Interactive debounce — fires fast (250 ms) so the user sees
    /// their Settings change land in the file before they tab over to
    /// look. Used by `SettingsStore`, where every change is a deliberate
    /// UI mutation and a longer wait reads as "did my edit take?".
    static let interactive: Duration = .milliseconds(250)

    /// Coalescing debounce — fires slow enough (400 ms) to batch a
    /// burst of mutations (notification storm, drag-reorder run, rapid
    /// command palette opens) into one write. Used by event-driven
    /// stores where individual mutations aren't user-visible
    /// individually and the cost is dominated by JSON encode + write.
    /// Expose both forms because callers split between Swift
    /// concurrency (`Task.sleep(for:)`) and GCD (`asyncAfter`).
    static let coalescingMs: Int = 400
    static var coalescing: Duration {
        .milliseconds(coalescingMs)
    }
}

// MARK: - JSON coder factory

/// The shared JSON config for the Codable stores that route through it
/// (`SessionStore`, `NotificationHistoryStore`, `FrecencyStore`, the read,
/// viewed-line, routing, stop, resume, and review-draft stores), so a
/// change here reaches each of their files. `SettingsStore` only decodes
/// through it: it writes `settings.json` with
/// `LimpidSettings.makeFileEncoder`. Not every file Limpid writes is among
/// them. `VersionedListFile` (`ended-session-hints.json`,
/// `turn-deletions.json`, `restore-pending-stops.json`), the migration
/// backup's record, and the service registration marker keep coders of
/// their own, and the per-pane agent records are written by the
/// hooks from shell and Rust, so their shape is a cross-language contract
/// rather than this factory's to set.
enum PersistenceCoders {
    /// Encoder with sorted keys (clean `git diff` over copied state
    /// files), ISO 8601 dates (forward-compat with any timezone-aware
    /// reader), and pretty-printed output in Debug (so the file is
    /// human-readable while inspecting at the prompt). Release builds
    /// strip pretty-printing to keep the on-disk size tight.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #if DEBUG
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        #else
            encoder.outputFormatting = [.sortedKeys]
        #endif
        return encoder
    }

    /// Decoder matched to `makeEncoder` — ISO 8601 dates round-trip
    /// with the same precision they were written. Configuring both
    /// from a single source means a date-format migration can't slip
    /// across stores asymmetrically.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
