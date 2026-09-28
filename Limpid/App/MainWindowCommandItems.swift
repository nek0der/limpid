// MainWindowCommandItems.swift
// Limpid — wraps menu items that act on the main window's session so they
// step aside while the quick terminal has the keyboard.

import SwiftUI

/// Menu items that act on the main window: its session, tabs, panes,
/// sidebar, palette, and review. While the quick terminal panel is key they
/// are disabled: the user is typing somewhere else, and ⌘T opening a tab
/// behind the panel reads as nothing happening.
///
/// We wrap whole command groups rather than gating each item, so an item
/// added to a group later is gated without anyone remembering to. An item
/// that must keep working in the panel (Close Pane, which hides it) stays
/// outside the wrapper. `.disabled` reaches every item through the
/// environment and combines with the item's own `.disabled`: an item is
/// enabled only when both allow it.
struct MainWindowCommandItems<Content: View>: View {
    let quickTerminal: QuickTerminalController
    let content: Content

    init(_ quickTerminal: QuickTerminalController, @ViewBuilder content: () -> Content) {
        self.quickTerminal = quickTerminal
        self.content = content()
    }

    var body: some View {
        content
            .disabled(quickTerminal.isPanelKey)
    }
}
