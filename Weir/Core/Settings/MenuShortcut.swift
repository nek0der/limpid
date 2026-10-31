// MenuShortcut.swift
// Weir — which shortcut an item in one of Weir's own menus (right-click, a header's ⋯, a row's) shows.

import Foundation

/// A command one of Weir's menus offers that a keyboard shortcut also
/// performs: the menu item is another way in to the same command, such as
/// the decision bar's ⋯ "Review Unviewed" for the menu bar's.
///
/// The rule every such menu follows: an item whose command a shortcut
/// performs shows that shortcut, read from the user's settings, so a
/// rebinding shows up here the moment it shows up in the menu bar. An item
/// no shortcut performs shows none, and so has no case here.
///
/// Apple's HIG lets a context menu leave shortcuts out, since the menu bar
/// already lists them. We show them anyway: most of Weir's shortcuts
/// (⌘D to split, ⌘⇧↩ to zoom a pane) belong to commands people reach for
/// in the pane they are working in, and the menu they open there is the
/// one place they would otherwise never meet the key.
///
/// A menu only shows the key; the menu bar stays the one place a shortcut
/// is live, so a keystroke made with no menu open does what it always did.
enum MenuCommand: CaseIterable {
    case copy
    case paste
    case selectAll
    case find
    case splitRight
    case splitDown
    case togglePaneZoom
    case closePane
    case renameTab
    case closeTab
    case newWorktree
    case keyboardShortcuts
    case reviewChanges

    var shortcutSource: MenuShortcutSource {
        switch self {
        case .copy: .standardEdit(StandardEditShortcut.copy)
        case .paste: .standardEdit(StandardEditShortcut.paste)
        case .selectAll: .standardEdit(StandardEditShortcut.selectAll)
        case .find: .action(.find)
        case .splitRight: .action(.splitRight)
        case .splitDown: .action(.splitDown)
        case .togglePaneZoom: .action(.toggleSplitZoom)
        case .closePane: .action(.closeSurface)
        case .renameTab: .action(.renameTab)
        case .closeTab: .action(.closeTab)
        case .newWorktree: .action(.newWorktree)
        case .keyboardShortcuts: .action(.keyboardShortcuts)
        case .reviewChanges: .action(.review)
        }
    }

    /// The shortcut the item shows, with the user's overrides applied.
    func shortcut(in keyboard: KeyboardSettings) -> StoredShortcut? {
        shortcut { keyboard.shortcut(for: $0) }
    }

    /// The shortcut the item shows, with `lookup` answering for Weir's
    /// rebindable actions. A menu with no settings to read passes a lookup
    /// that answers nil, and still shows the Edit menu's fixed keys.
    func shortcut(resolving lookup: (WeirShortcutAction) -> StoredShortcut?) -> StoredShortcut? {
        switch shortcutSource {
        case let .action(action): lookup(action)
        case let .standardEdit(shortcut): shortcut
        }
    }
}

/// Where a menu item's shortcut comes from.
enum MenuShortcutSource: Equatable {
    /// One of Weir's rebindable actions, read from settings.
    case action(WeirShortcutAction)
    /// A key the standard Edit menu owns.
    case standardEdit(StoredShortcut)
}

/// The standard Edit menu's keys for the commands Weir's menus repeat.
/// SwiftUI's default Edit menu owns them and sends them down the responder
/// chain, and Settings cannot rebind them (`WeirShortcutAction` leaves
/// Copy and Paste out for that reason), so they are fixed, and this is the
/// one place a menu reads them from.
enum StandardEditShortcut {
    static let copy = StoredShortcut(key: "c", modifiers: [.command])
    static let paste = StoredShortcut(key: "v", modifiers: [.command])
    static let selectAll = StoredShortcut(key: "a", modifiers: [.command])
}
