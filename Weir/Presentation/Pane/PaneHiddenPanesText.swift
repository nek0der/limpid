// PaneHiddenPanesText.swift
// Weir — the chip in a zoomed pane's header: how many panes the zoom hides, and what most needs the person among them.

import Foundation

enum PaneHiddenPanesText {
    /// "1 other pane · Needs approval"; the count alone with nothing waiting.
    static func line(_ hidden: PaneHeaderHiddenPanes, locale: Locale) -> String {
        let count = LocalizedStringResource(
            "\(hidden.count) other panes",
            comment: "Header of a zoomed pane: how many panes of the tab the zoom hides, with what most needs the person among them"
        ).resolved(in: locale)
        let state = hidden.glyph.map { [SessionRowFactText.stateName($0, locale: locale)] } ?? []
        return AgentStatusText.joined([count] + state, locale: locale)
    }
}
