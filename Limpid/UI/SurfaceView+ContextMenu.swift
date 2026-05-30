// SurfaceView+ContextMenu.swift
// Limpid — right-click context menu for terminal panes; modelled on
// Ghostty's macOS app and wired to libghostty actions + TabActions
// via the callbacks `PaneHostView` installs.

import AppKit
import GhosttyKit

extension SurfaceView {
    /// Right-click only. We deliberately don't surface a menu on
    /// Ctrl-left-click — libghostty's mouse pipeline already routes that
    /// to the running TUI, and intercepting it would break programs that
    /// bind Ctrl-click themselves.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }

        // AppKit calls menu(for:) BEFORE rightMouseDown and skips
        // rightMouseDown entirely when we return non-nil. Two
        // consequences we have to handle manually:
        //   1. Promote this pane to focused in both the AppKit
        //      responder chain AND the SwiftUI model — otherwise
        //      Split / Close / Find target the previously-focused
        //      pane (focusedLeafID is only written by .onTapGesture).
        //   2. Re-emit the right-mouse press to libghostty so TUIs
        //      with mouse reporting still see the click.
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        onRequestFocus?()
        sendRightMousePressForMenu(with: event)

        let menu = NSMenu()

        if let surface, ghostty_surface_has_selection(surface) {
            menu.addItem(
                withTitle: String(localized: "Copy"),
                action: #selector(copy(_:)),
                keyEquivalent: ""
            )
        }
        menu.addItem(
            withTitle: String(localized: "Paste"),
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Select All"),
            action: #selector(selectAll(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: String(localized: "Clear"),
            action: #selector(clearScreen(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Scroll to Top"),
            action: #selector(scrollToTop(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: String(localized: "Scroll to Bottom"),
            action: #selector(scrollToBottom(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Find…"),
            action: #selector(findInSurface(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())
        let splitRight = menu.addItem(
            withTitle: String(localized: "Split Right"),
            action: #selector(splitRight(_:)),
            keyEquivalent: ""
        )
        splitRight.image = NSImage(
            systemSymbolName: "rectangle.righthalf.inset.filled",
            accessibilityDescription: nil
        )
        let splitDown = menu.addItem(
            withTitle: String(localized: "Split Down"),
            action: #selector(splitDown(_:)),
            keyEquivalent: ""
        )
        splitDown.image = NSImage(
            systemSymbolName: "rectangle.bottomhalf.inset.filled",
            accessibilityDescription: nil
        )

        menu.addItem(.separator())
        let close = menu.addItem(
            withTitle: String(localized: "Close Pane"),
            action: #selector(closePaneFromMenu(_:)),
            keyEquivalent: ""
        )
        close.image = NSImage(
            systemSymbolName: "xmark.square",
            accessibilityDescription: nil
        )

        return menu
    }

    // MARK: - Action handlers

    @objc override func selectAll(_ sender: Any?) {
        runSurfaceBinding("select_all")
    }

    @objc func clearScreen(_ sender: Any?) {
        runSurfaceBinding("clear_screen")
    }

    @objc func scrollToTop(_ sender: Any?) {
        runSurfaceBinding("scroll_to_top")
    }

    @objc func scrollToBottom(_ sender: Any?) {
        runSurfaceBinding("scroll_to_bottom")
    }

    @objc func findInSurface(_ sender: Any?) {
        onRequestBeginSearch?()
    }

    @objc func splitRight(_ sender: Any?) {
        onRequestSplit?(.horizontal)
    }

    @objc func splitDown(_ sender: Any?) {
        onRequestSplit?(.vertical)
    }

    @objc func closePaneFromMenu(_ sender: Any?) {
        onRequestCloseActivePane?()
    }

    private func runSurfaceBinding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }
}

// MARK: - NSMenuItemValidation

/// Gates the right-click menu **and** any Edit-menu equivalents that
/// dispatch through the responder chain (`copy:` / `paste:` /
/// `selectAll:`). Without this, AppKit would leave every item enabled
/// even when the surface is gone or there's no selection.
extension SurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)),
             #selector(selectAll(_:)),
             #selector(clearScreen(_:)),
             #selector(scrollToTop(_:)),
             #selector(scrollToBottom(_:)),
             #selector(findInSurface(_:)),
             #selector(splitRight(_:)),
             #selector(splitDown(_:)),
             #selector(closePaneFromMenu(_:)):
            return surface != nil
        default:
            return true
        }
    }
}
