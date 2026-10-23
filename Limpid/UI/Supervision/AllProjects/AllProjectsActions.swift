// AllProjectsActions.swift
// Limpid — what the all projects sheet does: open a card's session, switching this window to its project, and close.

import AppKit

@MainActor
enum AllProjectsActions {
    /// Opens `card`: the pane of the item it shows, reached the same way
    /// ⌘J and the Needs Attention list reach it; otherwise its session. Either
    /// way this window switches to the card's project in place, or the
    /// window that shows it comes forward
    /// (`WindowRegistry.show(project:in:from:intent:)`). Another project
    /// counts toward project ▾'s order as choosing it there does. The sheet
    /// closes either way.
    ///
    /// ⌘-click or ⌘Return (`opensInNewWindow`) opens a card of another project in
    /// a new window instead (`WindowRegistry.openInNewWindow`), on the same
    /// item or session; a card of this window's project opens here.
    static func open(_ card: AllProjectsModel.Card, from window: ProjectWindowState, state: AppState, opensInNewWindow: Bool = false) {
        window.isAllProjectsPresented = false
        let isOtherProject = card.projectID != window.selection.shownProjectID
        if isOtherProject {
            state.frecencyStore.record(ProjectMenuModel.frecencyKey(card.projectID))
        }
        let opensInNewWindow = opensInNewWindow && isOtherProject
        if let id = card.leadItemID, let item = state.attentionQueue.queue.items.first(where: { $0.id == id }) {
            state.attentionQueue.focus(item, from: window, opensInNewWindow: opensInNewWindow)
            return
        }
        let registry = state.windowRegistry
        let shown = opensInNewWindow
            ? registry.openInNewWindow(project: card.projectID, in: state.session, from: window)
            : registry.show(project: card.projectID, in: state.session, from: window, intent: .person)
        guard let target = shown else {
            return
        }
        state.session.setActiveContainer(card.id, in: target.id, intent: .person)
        // A session already in front shows no new terminal to take the
        // keyboard the field held: its terminal is handed it.
        returnKeyboard(in: target, state: state)
    }

    /// Closes the sheet and hands the keyboard back to the window's
    /// terminal.
    static func close(_ window: ProjectWindowState, state: AppState) {
        window.isAllProjectsPresented = false
        returnKeyboard(in: window, state: state)
    }

    /// Gives the keyboard to `window`'s terminal unless a terminal has it,
    /// on the next turn, after the pane a card opened is drawn. The sheet's
    /// field still holds the keyboard while the sheet fades out, so, unlike
    /// after a rename, a text field does not get to keep it
    /// (`keeper: .terminal`).
    private static func returnKeyboard(in window: ProjectWindowState, state: AppState) {
        KeyboardHandoff.returnToFocusedPane(
            in: window.id,
            session: state.session,
            registry: state.registry,
            keeper: .terminal,
            timing: .nextTurn
        )
    }
}
