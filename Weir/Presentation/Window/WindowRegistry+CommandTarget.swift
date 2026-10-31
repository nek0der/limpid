// WindowRegistry+CommandTarget.swift
// Weir — which window a command acts on: a menu's, and one nothing has the keyboard for.

import Foundation

extension WindowRegistry {
    /// The window a menu command acts on: the main window that is key, as
    /// AppKit reports it (`keyWindowID`). `nil` when no main window is key
    /// — Settings, About, a sheet's own window, or the quick terminal in
    /// front — so the window-scoped items disable themselves and ⌘W closes
    /// that window (`CloseKeyCommand`). Acting in the main window that last
    /// had the keyboard instead would close a terminal tab behind Settings
    /// on ⌘W.
    ///
    /// AppKit's answer and no other, not SwiftUI's `@FocusedValue`, which is
    /// published only while SwiftUI's own focus system holds the keyboard —
    /// so with a terminal (an AppKit view) first responder it is `nil` in a
    /// key main window, and deciding from it would leave every window-scoped
    /// item off. Two sources would leave the two disagreeing; there is one.
    var commandTarget: ProjectWindowState? {
        keyWindowID.flatMap { window($0) }
    }

    /// The window code with no keyboard to read acts in — a toast, a
    /// notification's click, the menu bar extra, an agent's request, and
    /// ⌘J, which takes the person to what needs them wherever they are: the
    /// main window that last had the keyboard while it is still shown, else
    /// the primary. Not for a command that acts in a window's contents,
    /// which asks `commandTarget` and does nothing while no main window is
    /// key.
    var backgroundCommandTarget: ProjectWindowState {
        if let lastKeyWindowID, let window = window(lastKeyWindowID), !window.isHidden {
            return window
        }
        return primary
    }
}
