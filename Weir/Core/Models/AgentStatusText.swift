// AgentStatusText.swift
// Weir — the tooltips and spoken lists the views join from several facts.
//
// Each phrase is one catalog format string, so a translator can change
// the word order and the separators; the views only show the result. The
// results are `String`s because they are joined with the agent's own words
// (a turn's detail), and are resolved in the `locale` the caller is drawn in.

import Foundation

enum AgentStatusText {
    /// What sets two facts apart (" · "): `joined`'s own words, with
    /// nothing on either side.
    static func separator(locale: Locale) -> String {
        let nothing = ""
        return LocalizedStringResource(
            "\(nothing) · \(nothing)",
            comment: "Separates two facts in an agent tooltip; arguments: what came before, the next fact"
        ).resolved(in: locale)
    }

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

    /// Returns what a line says before its `fact`, and the separator that
    /// joins the two, as `joined` joins them: that joined line less the fact
    /// it ends with ("weir · "), so a view can set the two apart, in two
    /// colors or cut one before the other. It is `lead` alone when there is
    /// no fact.
    static func lead(_ lead: String, before fact: String, locale: Locale) -> String {
        guard !fact.isEmpty else { return lead }
        let line = joined([lead, fact], locale: locale)
        return line.hasSuffix(fact) ? String(line.dropLast(fact.count)) : lead + " · "
    }

    /// A pane header's state tooltip: the state glyph's name ("Needs
    /// approval"), then what the agent is doing when the badge says.
    static func pane(name: String, detail: String?, locale: Locale) -> String {
        joined([name, detail ?? ""], locale: locale)
    }

    /// Several spoken facts read as one element, in the locale's own list
    /// style ("a, b, c" / "a、b、c").
    static func spokenList(_ pieces: [String], locale: Locale) -> String {
        pieces.filter { !$0.isEmpty }.formatted(.list(type: .and, width: .narrow).locale(locale))
    }

    /// Facts that `joined` set off for the eye, as VoiceOver reads them:
    /// VoiceOver says " · " as a symbol ("middle dot") or runs the facts
    /// together, so they are read again as the locale's list.
    static func spoken(_ text: String, locale: Locale) -> String {
        spokenList(text.components(separatedBy: separator(locale: locale)), locale: locale)
    }

    /// Writes a place as the attention list and all projects' cards write
    /// it: "project / worktree", or the project alone when the checkout is
    /// not known or is the project's name over again. The worktree goes by
    /// its branch, also for a row the person labeled, and by its folder
    /// when no branch is known (`WorkspaceSession.rowCheckout(of:)`).
    static func place(project: String, checkout: String?) -> String {
        guard let checkout, !checkout.isEmpty, checkout != project else { return project }
        return "\(project) / \(checkout)"
    }

    /// A place written "project / worktree" (`WorkspaceSession.containerLabel`),
    /// as VoiceOver reads it: "project, worktree", not "slash". Only the
    /// spaced " / " sets the two apart; a branch's own "/" stays in its name.
    static func spokenPlace(_ text: String, locale: Locale) -> String {
        spokenList(text.components(separatedBy: " / "), locale: locale)
    }
}
