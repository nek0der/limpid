// TabCapabilities.swift
// Limpid — what a tab of a given kind lets the user do to its panes, in one table.

import Foundation

/// The operations a tab supports, read from one place. Menus, drop zones,
/// the geometry guards, and the close path all consult this instead of
/// testing `tab.kind` on their own, so enabling one verb for a kind later
/// is one row here rather than a hunt through the UI.
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
    /// The tab's title follows the title its focused pane's program sets
    /// (OSC 0/2). A mirror tab is named after its tmux window instead, the
    /// name the palette lists it by, and tmux announces that name when it
    /// changes (`%window-renamed`).
    var titleFollowsPaneTitle: Bool

    static func of(_ kind: Tab.Kind) -> TabCapabilities {
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
                titleFollowsPaneTitle: true
            )
        case .tmuxMirror:
            TabCapabilities(
                canSplit: true,
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
                titleFollowsPaneTitle: false
            )
        }
    }
}

extension Tab {
    var capabilities: TabCapabilities {
        TabCapabilities.of(kind)
    }
}
