// NewWindowText.swift
// Limpid — the words that say a row can open in a new window: its tooltip and its VoiceOver action.

import Foundation

/// What the rows that open a project say about ⌘: the
/// tooltip of project ▾'s rows, the all projects sheet's cards, and the
/// Needs Attention list's rows, and the VoiceOver action that does what
/// ⌘-click does, since a click with a key held is out of VoiceOver's reach.
enum NewWindowText {
    static func clickHelp(locale: Locale) -> String {
        LocalizedStringResource(
            "⌘-click to open in a new window",
            comment: "Tooltip of a row that opens another project: Command-click opens it in a new window"
        ).resolved(in: locale)
    }

    static let actionName = LocalizedStringResource(
        "Open in New Window",
        comment: "VoiceOver action on a row of another project: opens it in a new window, as Command-click does"
    )
}
