// TurnReplyText.swift
// Limpid — the words a turn's reply is said with where no mark leads it.

import Foundation

/// The words a turn's reply is said with where no mark leads it, as one
/// does on the card and in the notification history: a tooltip, and
/// VoiceOver, which reads no mark.
enum TurnReplyText {
    /// "Reply: Fixed the off-by-one in add()."
    static func labeled(_ reply: String, locale: Locale) -> String {
        LocalizedStringResource(
            "Reply: \(reply)",
            comment: "What the agent said as a turn ended, in a turn's tooltip and VoiceOver; argument: the reply's first paragraph"
        ).resolved(in: locale)
    }
}
