// NewWindowDockMenu.swift
// Limpid — the Dock icon's New Window, the way back once every window is closed.

import AppKit

/// The Dock menu's "New Window": with every window closed, the
/// one left hidden comes back; otherwise a window that shows nothing
/// opens (`WindowRegistry.openEmptyWindow`). macOS lists the windows
/// shown above it itself, and leaves out a hidden one.
///
/// The Dock sends the item's action to its target as the item is chosen
/// (`NSApplicationDelegate.applicationDockMenu(_:)`), so the target is
/// an object that lives as long as the app: a menu item holds its target
/// weakly, and the app delegate's closure that makes the menu holds this
/// object.
@MainActor
final class NewWindowDockMenu: NSObject {
    private let open: () -> Void
    /// The language the item's title is read in: the app's own setting.
    private let locale: () -> Locale

    init(locale: @escaping () -> Locale, open: @escaping () -> Void) {
        self.locale = locale
        self.open = open
    }

    /// The menu, made anew each time the Dock asks, in the app's language
    /// as it is then.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: LimpidShortcutAction.newWindow.localizedTitle.resolved(in: locale()),
            action: #selector(newWindow(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newWindow(_: Any?) {
        open()
    }
}
