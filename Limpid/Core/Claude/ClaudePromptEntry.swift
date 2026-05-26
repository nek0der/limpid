// ClaudePromptEntry.swift
// Limpid — a single user-submitted prompt captured by the
// `UserPromptSubmit` hook. Surfaced in the per-pane prompt-history
// sidebar; the index doubles as the position of the matching OSC
// 133;A marker the hook emits into the terminal, so tapping a row
// maps cleanly to ghostty's `jump_to_prompt:-<delta>` binding action.

import Foundation

struct ClaudePromptEntry: Codable, Equatable, Identifiable, Hashable {
    /// Stable id for SwiftUI ForEach diffing. Generated client-side
    /// when decoding because the on-disk record only carries the
    /// array position.
    var id: UUID = .init()
    /// Zero-based position in the pane's prompt history. Tapping
    /// entry N when the history has total prompts T means
    /// `jump_to_prompt:-(T - 1 - N)` — the cursor sits at the latest
    /// marker after the most recent prompt submit, and `jump_to_prompt`
    /// is relative to the current viewport.
    var index: Int
    /// ISO-8601 instant the prompt was submitted. Stored as String to
    /// match the rest of the hook's on-disk shape and avoid encoder
    /// quirks across architectures.
    var submittedAt: String
    /// The prompt text. May be empty / partial when the sed extraction
    /// in `limpid-hook` couldn't parse a payload with embedded quotes
    /// / backslashes / multi-line input — UI callers should be ready
    /// to render an empty row gracefully.
    var text: String

    private enum CodingKeys: String, CodingKey {
        case index, submittedAt, text
    }
}
