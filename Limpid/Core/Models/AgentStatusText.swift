// AgentStatusText.swift
// Limpid — the tooltips and spoken labels that describe agent states in
// the rows and pane headers.
//
// Each phrase is one catalog format string, so a translator can change
// the word order and the separators; the views only show the result. The
// results are `String`s because they are joined with the agent's own words
// (a turn's detail), and are resolved in the `locale` the caller is drawn in.

import Foundation

extension AgentState {
    /// What VoiceOver says for the state's glyph. `description` stands in
    /// for the bare state name where a site has more to say — the rows
    /// speak their pane breakdown — and a viewed completion is named as
    /// such either way, since the outline that shows it is drawn, not said.
    func accessibilityLabel(isViewedFinished: Bool, description: String? = nil, locale: Locale) -> String {
        let base = description ?? localizedLabel.resolved(in: locale)
        guard self == .finished, isViewedFinished else { return base }
        return LocalizedStringResource(
            "\(base), Viewed",
            comment: "Spoken label of a finished turn the user has looked at; argument: the state or the pane breakdown"
        ).resolved(in: locale)
    }
}

enum AgentStatusText {
    /// Facts in a tooltip, in order, each set off from the one before.
    static func joined(_ pieces: [String], locale: Locale) -> String {
        pieces.filter { !$0.isEmpty }.reduce("") { text, piece in
            text.isEmpty
                ? piece
                : LocalizedStringResource(
                    "\(text) · \(piece)",
                    comment: "Separates two facts in an agent tooltip; arguments: what came before, the next fact"
                ).resolved(in: locale)
        }
    }

    /// The container row's tooltip: how many panes are in each state, most
    /// urgent first ("1 error · 2 needs input"), or the dominant state alone
    /// when there is no breakdown.
    static func breakdown(_ counts: [AgentState: Int], dominant: AgentState, locale: Locale) -> String {
        let order: [AgentState] = [.error, .needsInput, .finished, .running, .compacting, .idle, .unknown]
        let parts = order.compactMap { state -> String? in
            guard let count = counts[state], count > 0 else { return nil }
            return LocalizedStringResource(
                "\(count) \(state.localizedLabel)",
                comment: "Agent breakdown tooltip entry; arguments: a pane count, an agent state"
            ).resolved(in: locale)
        }
        return parts.isEmpty ? dominant.localizedLabel.resolved(in: locale) : joined(parts, locale: locale)
    }

    /// The tab row's tooltip: the state, how many of the tab's panes share
    /// it (`panes`) when more than one does, what the most recent of them is
    /// doing, and for a running turn how long it has run.
    static func tab(
        state: AgentState,
        panes: (matching: Int, total: Int),
        detail: String?,
        elapsedSeconds: Int?,
        locale: Locale
    ) -> String {
        var label = state.hasVisibleBadge ? state.localizedLabel.resolved(in: locale) : ""
        if panes.matching > 1 {
            label = LocalizedStringResource(
                "\(label) (\(panes.matching) of \(panes.total) panes)",
                comment: "Agent state tooltip; arguments: the state, the panes in it, the panes in the tab"
            ).resolved(in: locale)
        }
        let elapsed = elapsedSeconds.map {
            Duration.seconds($0).formatted(.units(allowed: [.seconds], width: .narrow).locale(locale))
        }
        return joined([label, detail ?? "", elapsed ?? ""], locale: locale)
    }

    /// A pane header's state tooltip: the state, then what the agent is
    /// doing when the badge says, as the tab row phrases a single pane.
    static func pane(state: AgentState, detail: String?, locale: Locale) -> String {
        joined([state.localizedLabel.resolved(in: locale), detail ?? ""], locale: locale)
    }

    /// Several spoken facts read as one element, in the locale's own list
    /// style ("a, b, c" / "a、b、c").
    static func spokenList(_ pieces: [String], locale: Locale) -> String {
        pieces.filter { !$0.isEmpty }.formatted(.list(type: .and, width: .narrow).locale(locale))
    }
}
