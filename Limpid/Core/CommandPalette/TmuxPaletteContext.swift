// TmuxPaletteContext.swift
// Limpid — what the palette has to know about tmux to draw its tmux rows, resolved once when the palette opens.

import Foundation

/// The tmux facts the palette's rows read: whether each verb can run now
/// and, when it cannot, the words that say why.
///
/// A value rather than the stores themselves, so the catalog stays a pure
/// function of what it is given and every row — including the reason a
/// disabled one gives — can be checked without a tmux, a window, or a
/// surface registry.
struct TmuxPaletteContext: Equatable {
    /// Whether this Mac has a tmux at all. The rows that ask something of
    /// tmux are left out entirely without one: a palette on a Mac with no
    /// tmux has nothing to say about it.
    var hasTmux = false
    /// Why "New tmux Window" is disabled, or nil when it can run (D1).
    var newWindowObstacle: String?
    /// Why "New tmux Session" is disabled, or nil when it can run (D2).
    var newSessionObstacle: String?
    /// The focused pane that is attached to a tmux session by hand, or nil
    /// when the pane the user is in runs no tmux client (D5).
    var manualSessionPaneID: UUID?
    /// What that session is called, shown under the row so the user can see
    /// which session they would be shown.
    var manualSessionName: String?

    /// No tmux and nothing to offer: what a palette opened without a store
    /// gets. The verbs still carry a reason, because one of them has a
    /// shortcut of its own and a user who presses it is owed the answer
    /// even where the row is not listed.
    static let unavailable = TmuxPaletteContext(
        hasTmux: false,
        newWindowObstacle: String(localized: "no tmux found"),
        newSessionObstacle: String(localized: "no tmux found")
    )

    /// Resolve the context from the live stores. Every answer is read here,
    /// at the moment the palette opens, because a palette row is drawn once
    /// and the state behind it can change while it is up.
    @MainActor
    static func make(
        session: WindowSession,
        store: TmuxConnectionStore?,
        presence: TmuxPanePresence?,
        support: AgentTmuxSupport
    ) -> Self {
        guard let store, store.tmuxExecutable != nil else { return .unavailable }
        var context = Self(hasTmux: true)
        context.newWindowObstacle = TmuxSessionActions.newWindowObstacle(session: session, store: store)
        context.newSessionObstacle = TmuxSessionActions.newSessionObstacle(support: support, hasTmux: true)
        if let presence,
           let paneID = session.activeTab?.splitTree.effectiveFocusedLeafID,
           let binding = TmuxSessionActions.manualSession(paneID: paneID, session: session, presence: presence)
        {
            context.manualSessionPaneID = paneID
            context.manualSessionName = binding.sessionName
        }
        return context
    }
}
