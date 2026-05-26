// ClaudePromptRecord.swift
// Limpid — on-disk shape for the per-pane prompt history written by
// `Limpid/Resources/claude-shim/limpid-hook` on every
// `UserPromptSubmit` event. One file per pane, JSON-encoded array.

import Foundation

struct ClaudePromptRecord: Codable, Equatable {
    /// Bumped on a breaking on-disk migration. Records that don't
    /// match the expected version are ignored by callers.
    var schemaVersion: Int
    /// UUID of the owning split-tree leaf. Must equal the filename
    /// stem (defense in depth against path-traversal via crafted env).
    var paneId: String
    /// ISO-8601 instant of the last write to this file. Useful for
    /// the cleanup pass to drop old records and for tests that check
    /// the hook actually re-wrote the file.
    var updatedAt: String
    /// All prompts the user has submitted in this pane's current
    /// session, in submit order. The array index is the prompt's
    /// position and aligns 1:1 with the OSC 133;A markers the hook
    /// emits — that pairing is what lets the sidebar jump the
    /// terminal to a clicked prompt's location via ghostty's
    /// `jump_to_prompt` binding action.
    var prompts: [ClaudePromptEntry]
}
