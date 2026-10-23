// AllProjectsText.swift
// Limpid — the all projects sheet's words: its counts, its sections, a card's place and window.

import Foundation

enum AllProjectsText {
    /// "Needs Attention 3 · Running 2" at the top of the sheet: the
    /// title bar's number, then the sessions running.
    static func counts(attention: Int, running: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "Needs Attention \(attention) · Running \(running)",
            comment: "All projects sheet: the attention items and the running sessions"
        ).resolved(in: locale)
    }

    /// A section's name, which its heading sets apart from its number of
    /// cards.
    static func sectionName(_ section: AllProjectsModel.Section, locale: Locale) -> String {
        let name: LocalizedStringResource = switch section {
        case .needsAttention: "Needs Attention"
        case .running: "Running"
        case .idle: "Idle"
        }
        return name.resolved(in: locale)
    }

    /// A section's heading with its number of cards, as VoiceOver reads it.
    static func section(_ section: AllProjectsModel.Section, count: Int, locale: Locale) -> String {
        switch section {
        case .needsAttention:
            LocalizedStringResource("Needs Attention \(count)", comment: "All projects sheet: section heading and its card count")
                .resolved(in: locale)
        case .running:
            LocalizedStringResource("Running \(count)", comment: "All projects sheet: section heading and its card count")
                .resolved(in: locale)
        case .idle:
            LocalizedStringResource("Idle \(count)", comment: "All projects sheet: section heading and its card count")
                .resolved(in: locale)
        }
    }

    /// "limpid / feat/pricing", or the project alone when the branch is not
    /// known. A card the person named is placed by the folder its sidebar
    /// row shows beside that name ("limpid / login-redesign"), which says
    /// which worktree it is where the name no longer does.
    static func place(project: String, branch: String?, folder: String? = nil) -> String {
        AgentStatusText.place(project: project, checkout: folder ?? branch)
    }

    /// `place` as VoiceOver reads it, "limpid, feat/pricing": the spaced
    /// " / " would be read aloud as "slash".
    static func spokenPlace(project: String, branch: String?, folder: String? = nil, locale: Locale) -> String {
        guard let checkout = folder ?? branch, !checkout.isEmpty, checkout != project else { return project }
        return AgentStatusText.spokenList([project, checkout], locale: locale)
    }

    static func windowNote(_ note: AllProjectsModel.WindowNote, locale: Locale) -> String {
        switch note {
        case .current:
            LocalizedStringResource("Current Window", comment: "All projects card: the project of the window the sheet is in")
                .resolved(in: locale)
        case .otherWindow:
            LocalizedStringResource(
                "Other Window",
                comment: "Another window shows this project: choosing it brings that window forward"
            ).resolved(in: locale)
        }
    }
}
