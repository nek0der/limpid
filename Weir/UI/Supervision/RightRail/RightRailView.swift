// RightRailView.swift
// Weir — the right tool window bar: the changes panel of the current session.

import SwiftUI

/// The right rail: the entry to what changes with the current session.
/// One icon for now, the changes panel, counting the session's turns
/// waiting to be read across its agents (none at zero).
struct RightRailView: View {
    let state: AppState
    @Environment(SettingsStore.self) private var settings
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale

    var body: some View {
        // Read once, for the badge and the tooltip both.
        let facts = ChangesPanelActions.railFacts(window: window, stores: state.changesPanelStores)
        let unviewed = facts.unviewed
        let shortcut = settings.settings.keyboard.shortcut(for: .toggleChangesPanel)?.displayString
        RailColumn {
            // A diff, which is what the panel reads, rather than the menu's
            // sidebar symbol, which says only where it goes.
            RailButton(
                systemImage: "plus.forwardslash.minus",
                name: "Changes",
                shortcut: shortcut,
                isSelected: window.selection.isChangesPanelPresented,
                badge: .counting(unviewed),
                help: ChangesPanelText.railHelp(shortcut: shortcut, unviewed: unviewed, agents: facts.agents, locale: locale),
                badgeLabel: ConversationText.unviewedTurns(unviewed, locale: locale)
            ) {
                ChangesPanelActions.toggle(window, session: state.session)
            }
        } bottom: {
            EmptyView()
        }
        // The count needs the worktree's top level, closed panel or not.
        .task(id: ChangesPanelActions.folder(window: window, stores: state.changesPanelStores)) {
            await ChangesPanelActions.resolveRoot(window: window, stores: state.changesPanelStores)
        }
    }
}
