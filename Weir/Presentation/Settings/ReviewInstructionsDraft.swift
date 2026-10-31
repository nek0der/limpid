// ReviewInstructionsDraft.swift
// Weir — the review instructions as Settings edits them: the text in effect, saved as "" while it is the default.

import Foundation

/// `advanced.reviewInstructions` keeps "" for "the default text, in the app's
/// language", so a reader who never changed it follows the default when the
/// language or a later build changes it. The editor shows the text in effect
/// instead of a placeholder, so adding one line to the default is an edit of
/// what is on screen; this maps between the two.
enum ReviewInstructionsDraft {
    /// The languages a default can be in; text equal to any of them is the
    /// default, so switching languages with the editor open never saves one
    /// language's default as the reader's own text.
    static let languages = ["en", "ja"]

    /// What the editor shows for `saved`: the reader's own text, or the
    /// default in `locale`.
    static func text(saved: String, locale: Locale) -> String {
        saved.isEmpty ? ReviewPromptBuilder.defaultInstructions.resolved(in: locale) : saved
    }

    /// What is saved for `text`: "" when it is a default (whitespace at the
    /// ends aside), else the text as written.
    static func saved(text: String, defaults: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = trimmed.isEmpty
            || defaults.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
        return isDefault ? "" : text
    }

    /// The defaults `saved(text:defaults:)` compares with, in every language.
    static var defaults: [String] {
        languages.map { ReviewPromptBuilder.defaultInstructions.resolved(in: Locale(identifier: $0)) }
    }
}
