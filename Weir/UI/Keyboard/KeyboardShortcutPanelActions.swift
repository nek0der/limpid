// KeyboardShortcutPanelActions.swift
// Weir — what the keyboard shortcuts panel does: open as the window's one layer, close, and take its keys.

import AppKit

/// Opening and closing the keyboard shortcuts panel over a window. It is
/// one of the window's layers (`WindowLayer`): what is open goes as the
/// panel comes, and the panel goes as another comes
/// (`ProjectWindowState.isAnotherLayerOpen`).
@MainActor
enum KeyboardShortcutPanelActions {
    /// ⌘/ and Help → Keyboard Shortcuts: opens the panel, or closes it.
    static func toggle(_ window: ProjectWindowState, session: WorkspaceSession, registry: any SurfaceViewProviding) {
        if window.keyboardShortcuts.isPresented {
            close(window, session: session, registry: registry)
        } else {
            open(window, session: session)
        }
    }

    static func open(_ window: ProjectWindowState, session: WorkspaceSession) {
        window.openWindowOverlay(.keyboardShortcuts, session: session)
    }

    /// Closes the panel and hands the keyboard back to the window's
    /// terminal, on the next turn. The panel's field still holds it
    /// while the panel fades out, so a text field does not keep it, as for
    /// All Projects (`AllProjectsActions.close`).
    static func close(_ window: ProjectWindowState, session: WorkspaceSession, registry: any SurfaceViewProviding) {
        window.keyboardShortcuts.isPresented = false
        KeyboardHandoff.returnToFocusedPane(
            in: window.id,
            session: session,
            registry: registry,
            keeper: .terminal,
            timing: .nextTurn
        )
    }
}

/// The keys the panel takes at its window (`WindowOverlayKeyMonitor`). The
/// keyboard stays in the search field; Tab and ⇧Tab go through the panel's
/// controls, drawn with the accent's ring, rather than to a view under the
/// dimmed window, and Return presses the one the ring is on.
enum KeyboardShortcutPanelKeys {
    enum Key: Equatable {
        case close
        case nextControl
        case previousControl
        case press
    }

    /// What Tab moves through, in the panel's order.
    enum Control: CaseIterable, Equatable {
        case search
        case customize
        case close

        /// The control after this one, or before it with `backward`,
        /// round the panel.
        func next(backward: Bool) -> Control {
            let all = Self.allCases
            let index = all.firstIndex(of: self) ?? 0
            let step = backward ? all.count - 1 : 1
            return all[(index + step) % all.count]
        }
    }

    /// The panel's key for `event`, or `nil` for one it leaves alone, such
    /// as a letter for the field or a shortcut for the menus.
    static func key(for event: NSEvent) -> Key? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        return switch event.namedKey {
        case .escape: .close
        case .tab: event.modifierFlags.contains(.shift) ? .previousControl : .nextControl
        case .return: .press
        default: nil
        }
    }
}
