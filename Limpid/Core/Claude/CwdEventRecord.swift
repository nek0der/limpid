// CwdEventRecord.swift
// Limpid — on-disk shape of a `CwdChanged` hook event written by
// `Limpid/Resources/claude-shim/limpid-hook`. Each Claude pane keeps
// a single `<pane>.cwd.json` that is overwritten on every cwd
// transition; `CwdEventTracker` watches the directory and routes
// fresh records to `WorktreeMoveSuggester`.

import Foundation

struct CwdEventRecord: Codable, Equatable {
    /// Bumped on a breaking on-disk migration. Records that don't
    /// match the expected version are ignored by callers.
    var schemaVersion: Int
    /// UUID of the owning split-tree leaf. Must equal the filename
    /// (defense in depth against path-traversal via crafted env).
    var paneId: String
    /// The directory Claude moved into. Absolute path; symlinks are
    /// left un-resolved because the agent itself sees them un-resolved.
    var newCwd: String
    /// The directory Claude moved out of. Empty when the hook payload
    /// didn't carry it (some Claude builds only ship `cwd`); callers
    /// treat `""` the same as `nil`.
    var oldCwd: String?
    /// ISO-8601 instant of this record's write. Tracker compares
    /// incoming `updatedAt` against its previous snapshot to detect
    /// fresh events without re-processing on every directory scan.
    var updatedAt: String
}
