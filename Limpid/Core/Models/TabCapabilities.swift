// TabCapabilities.swift
// Limpid — what a tab of a given kind lets the user do to its panes, in one table.

import Foundation

/// The operations a tab supports, read from one place. Menus, drop zones,
/// the geometry guards, and the close path all consult this instead of
/// testing `tab.kind` on their own, so enabling one verb for a kind later
/// is one row here rather than a hunt through the UI.
///
/// The table answers what a tab *lets the user do*. It is not the place to
/// ask what a mirror tab *is*: how a mirror pane is drawn, how its geometry
/// is derived from the tmux layout, and how a resize is reported all belong
/// to the mirror itself and read `kind == .tmuxMirror` directly, because
/// there is no verb to enable or refuse there and a row would only be a
/// second name for the kind. A verb the user invokes — a menu item, a drop,
/// a shortcut, a palette command — asks the table instead, and a test pins
/// which row it asks (`TabCapabilitiesTests`).
///
/// A tmux mirror tab translates the verbs it allows into tmux commands and
/// waits for `%layout-change` to draw the result (design §10). What it
/// disallows either has no tmux counterpart (inserting a pane at an edge
/// is not a swap and not a join), would lie to the user (closing a pane
/// runs an agent check that cannot see a tmux pane), or would collide with
/// the mirror's own size reporting (review's docked strip).
struct TabCapabilities: Equatable {
    /// Split the focused pane (Command-D and friends).
    var canSplit: Bool
    /// Swap two panes by dropping one on the center of the other.
    var canSwap: Bool
    /// Detach a pane and insert it beside another (an edge drop).
    var canInsert: Bool
    /// Spread every pane of the tab evenly.
    var canEqualize: Bool
    /// Spread one subtree evenly (double-click on its divider).
    var canEqualizeSubtree: Bool
    /// Close the focused pane (Command-W).
    var canClosePane: Bool
    /// Drop a file onto a pane to type its path.
    var canDropFile: Bool
    /// Input that is not a keystroke, a paste and the paths a file drop
    /// types, goes to tmux as a paste buffer (`TmuxMirrorActions.paste`
    /// and `dropFiles`) instead of through libghostty: only tmux knows
    /// whether the program in the pane wants it bracketed. Only a mirror
    /// tab holds mirror surfaces, so this row and the kind of surface a
    /// pane has always agree.
    var sendsInputThroughTmux: Bool
    /// Clear the screen and scrollback from the pane's menu. libghostty
    /// erases its own copy and asks the shell to redraw only when it has
    /// seen the shell's prompt marks. On a mirror pane tmux keeps the rows,
    /// so they come back with the next repaint from tmux, while the
    /// scrollback erased here is the only copy the pane shows. tmux has no
    /// command that does the same to a pane, so the item is refused there.
    var canClearScreen: Bool
    /// Receive a pane dragged out of another tab.
    var canAcceptForeignPane: Bool
    /// Show the review surface over the tab.
    var canOpenReview: Bool
    /// Font shortcuts change every pane of the tab, not only the focused
    /// one: the panes share one cell grid.
    var appliesFontToEveryPane: Bool
    /// The tab's title follows the title its agent or its focused pane's
    /// program sets (the projection's `tab_titles`, OSC 0/2). A user's
    /// mirror tab is named after its tmux window instead, the name the
    /// palette lists it by. An agent's mirror tab is named after the agent,
    /// as the same agent's tab would be without tmux (design §6 decision
    /// 12): its window is one Limpid made, and the name tmux gives it says
    /// nothing the user chose.
    var titleFollowsPaneTitle: Bool
    /// The tab's title follows its tmux window's name, which tmux announces
    /// when it changes (`%window-renamed`). Never true together with
    /// `titleFollowsPaneTitle`, so one tab has one source for its name.
    var titleFollowsWindowName: Bool

    /// The table. A mirror tab's rows also depend on who opened it.
    ///
    /// An agent's mirror tab does not split: the shim hands the agent its
    /// leaf id through `new-session -e LIMPID_PANE_ID`, which tmux keeps in
    /// the session's environment, so a pane `split-window` made would start
    /// a shell under the same id and anything it ran would be taken for the
    /// agent (design §6 decision 4). With one pane, Close Pane is the tab's
    /// close (`PaneActions.canClosePaneOrTab`), and `break-pane` has nothing
    /// to move.
    static func of(_ kind: Tab.Kind, origin: Tab.MirrorOrigin = .user) -> TabCapabilities {
        switch kind {
        case .terminal:
            TabCapabilities(
                canSplit: true,
                canSwap: true,
                canInsert: true,
                canEqualize: true,
                canEqualizeSubtree: true,
                canClosePane: true,
                canDropFile: true,
                sendsInputThroughTmux: false,
                canClearScreen: true,
                canAcceptForeignPane: true,
                canOpenReview: true,
                appliesFontToEveryPane: false,
                titleFollowsPaneTitle: true,
                titleFollowsWindowName: false
            )
        case .tmuxMirror:
            TabCapabilities(
                canSplit: origin == .user,
                canSwap: true,
                canInsert: false,
                canEqualize: true,
                canEqualizeSubtree: false,
                canClosePane: false,
                canDropFile: true,
                sendsInputThroughTmux: true,
                canClearScreen: false,
                canAcceptForeignPane: false,
                canOpenReview: false,
                appliesFontToEveryPane: true,
                titleFollowsPaneTitle: origin == .agent,
                titleFollowsWindowName: origin == .user
            )
        }
    }
}

extension Tab {
    var capabilities: TabCapabilities {
        TabCapabilities.of(kind, origin: mirrorOrigin)
    }
}
