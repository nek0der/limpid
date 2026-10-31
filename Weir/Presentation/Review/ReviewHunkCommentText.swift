// ReviewHunkCommentText.swift
// Weir — the words of a review hunk header's "Comment".

import Foundation

/// The words of a hunk header's "Comment".
enum ReviewHunkCommentText {
    static func comment(locale: Locale) -> String {
        // The gutter's own key: one word for one action.
        LocalizedStringResource("Comment").resolved(in: locale)
    }

    static func commentHelp(locale: Locale) -> String {
        LocalizedStringResource(
            "Comments on this hunk’s change",
            comment: "Review: tooltip of Comment on a hunk header"
        ).resolved(in: locale)
    }

    /// "Comment on the Hunk at Line 3" for VoiceOver, which tells one
    /// hunk's "Comment" from another's in its list of buttons. The hunk is
    /// named by the line its new side starts at: its `@@ -3,3 +3,4 @@`
    /// line would be read symbol by symbol. A deleted file's hunk has no
    /// new side (`+0,0`), so it is named by its old side's first line. A
    /// header that names no line gives the button's own word.
    static func commentLabel(header: String, locale: Locale) -> String {
        guard let line = firstLine(of: header) else { return comment(locale: locale) }
        return LocalizedStringResource(
            "Comment on the Hunk at Line \(line)",
            comment: "Review, VoiceOver: Comment on a hunk header; argument: the line the hunk's new side starts at"
        ).resolved(in: locale)
    }

    /// The new side's first line in a hunk's `@@ -a,b +c,d @@` line, or
    /// the old side's where the new side is empty (`+0,0`).
    static func firstLine(of header: String) -> Int? {
        guard let match = header.firstMatch(of: /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,(\d+))?/),
              let old = Int(match.1), let new = Int(match.2)
        else { return nil }
        let isNewSideEmpty = new == 0 || match.3.flatMap { Int($0) } == 0
        return isNewSideEmpty ? old : new
    }
}
