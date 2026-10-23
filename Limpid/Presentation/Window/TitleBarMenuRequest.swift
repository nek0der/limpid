// TitleBarMenuRequest.swift
// Limpid — which of the title bar's dropdowns is open in a window, and what it hangs from.

import CoreGraphics
import Foundation

/// An open dropdown of the window's chrome: the title bar's project menu,
/// worktree menu, or Needs Attention list, or the pane strip's "+". They
/// are floating panels on the app's one surface (the same fill, edge,
/// shadow, and 16pt corners, no arrow), so the request carries the
/// control's frame the panel hangs from. One is open at a time.
struct TitleBarMenuRequest: FloatingPanelRequest, Equatable {
    enum Menu: Equatable {
        case project
        case worktree
        case needsAttention
        /// The pane strip's "+" for the session in this container.
        case addTab(ContainerID)
    }

    let id = UUID()
    let menu: Menu
    /// The control that opened it, in global coordinates.
    let anchor: CGRect
    /// Opened by its command (⌃⌘J, or its menu item, which shows that
    /// key) rather than by a press on its control.
    var isOpenedFromKeyboard = false

    /// Where the Needs Attention list's keyboard starts. Opened by a
    /// press, on no row, as the menu bar's list and every menu open, so
    /// nothing looks chosen before the person has chosen. Opened by ⌃⌘J,
    /// on the first row: the keys opened it to pick a row with ↑↓ and
    /// Return, and Return then opens the row the list shows first.
    var needsAttentionOpening: NeedsAttentionListSelection.Opening {
        isOpenedFromKeyboard ? .firstRow : .nothing
    }
}

extension ProjectWindowState {
    /// The control's press, or its key (`isOpenedFromKeyboard`): opens its
    /// dropdown, closes it when it is the one open, and replaces another
    /// one, since only one hangs from the title bar at a time.
    func toggleTitleBarMenu(_ menu: TitleBarMenuRequest.Menu, anchor: CGRect, isOpenedFromKeyboard: Bool = false) {
        titleBarMenu = titleBarMenu?.menu == menu
            ? nil
            : TitleBarMenuRequest(menu: menu, anchor: anchor, isOpenedFromKeyboard: isOpenedFromKeyboard)
    }
}
