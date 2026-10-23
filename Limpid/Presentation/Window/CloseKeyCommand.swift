// CloseKeyCommand.swift
// Limpid — what ⌘W does, by which window has the keyboard.

import Foundation

/// The File menu's ⌘W item, "Close" in every case below. One item carries
/// the key for the whole app: SwiftUI's standard Close is removed
/// (`TabCommands`), so an item of ours that is disabled leaves ⌘W doing
/// nothing. So with no supervision window key the item does not go dark;
/// it closes the window that is key (Settings, About), as the standard
/// item would have.
enum CloseKeyCommand: Equatable {
    /// The quick terminal has the keyboard: ⌘W hides it.
    case hideQuickTerminal
    /// The review tab is in front of the supervision window's tabs: ⌘W
    /// closes it, not a tab behind it.
    case closeReview
    /// The supervision window's focused pane, cascading to its tab.
    case closePaneOrTab
    /// No supervision window is key: the key window itself.
    case closeKeyWindow
    /// A supervision window is key with nothing to close; the item is off.
    case nothing

    /// `target` is the key supervision window (`WindowRegistry.commandTarget`),
    /// `nil` when none is.
    @MainActor
    static func decide(isQuickTerminalKey: Bool, target: ProjectWindowState?, hasActiveTab: Bool) -> Self {
        if isQuickTerminalKey {
            return .hideQuickTerminal
        }
        guard let target else { return .closeKeyWindow }
        if target.review?.isShown == true {
            return .closeReview
        }
        return hasActiveTab ? .closePaneOrTab : .nothing
    }

    /// Whether the item is enabled.
    var isLive: Bool {
        self != .nothing
    }
}
