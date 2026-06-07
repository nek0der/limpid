// PersistenceConstants.swift
// Limpid — named timings + a single JSON coder factory shared by
// every top-level Codable store. Per-store ad-hoc constants used to
// drift (250 vs 400 ms debounces, `.iso8601` set in some places and
// omitted in others, `.prettyPrinted` Debug-only on three stores and
// always-on on a fourth); centralizing them keeps the on-disk shape
// uniform and makes future timing / format changes one-line edits.

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

/// Canonical JSON config every Limpid Codable store routes through.
/// All four top-level stores (`SessionStore`, `SettingsStore`,
/// `NotificationHistoryStore`, `FrecencyStore`) hand encoding /
/// decoding off here so a single change here lands uniformly across
/// every on-disk file. Per-pane agent stores keep their own tighter
/// config because they write tiny records on the hot path and the
/// shim writes them in parallel from shell.
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
