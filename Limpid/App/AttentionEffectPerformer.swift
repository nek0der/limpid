// AttentionEffectPerformer.swift
// Limpid — carries out what an attention change asks for: the VoiceOver announcement, and a request's banner.

import SwiftUI

/// Performs the attention list's effects. In the app layer because they
/// speak through VoiceOver and post notifications, which the rules below
/// it may not touch.
@MainActor
struct AttentionEffectPerformer {
    /// Weak because the app state keeps this performer for as long as it
    /// lives.
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
    }

    func perform(_ effects: [AttentionEffect]) {
        for effect in effects {
            switch effect {
            case let .announce(id):
                announce(id)
            case let .notify(id):
                state?.postRequestBanner(for: id)
            }
        }
    }

    /// Says what is waiting and where: "Needs approval, Fix the login test".
    /// The state names are the ones the session rows speak, and a wait
    /// Limpid does not hold is named as the row names it.
    private func announce(_ id: AttentionItemID) {
        guard let state, let item = state.attentionQueue.queue.items.first(where: { $0.id == id }) else { return }
        // The language picked in Settings, which can differ from the one
        // the process launched with.
        let locale = state.settingsStore.appLocale
        let tabTitle = item.subject.paneID.flatMap { state.session.tab(containing: $0) }?.shownTitle
        AccessibilityNotification.Announcement(Self.announcement(of: item.kind, tabTitle: tabTitle, locale: locale)).post()
    }

    /// The words of an item's announcement: its state as its row's glyph
    /// names it, then the tab it is in.
    nonisolated static func announcement(of kind: AttentionItemKind, tabTitle: String?, locale: Locale) -> String {
        let name = SessionRowFactText.stateName(SessionRowFact.glyph(of: kind), locale: locale)
        return AgentStatusText.spokenList([name, tabTitle ?? ""], locale: locale)
    }
}
