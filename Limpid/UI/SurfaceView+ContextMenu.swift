// SurfaceView+ContextMenu.swift
// Limpid — right-click context menu for terminal panes; modelled on
// Ghostty's macOS app and wired to libghostty actions + TabActions
// via the callbacks `PaneHostView` installs.

import AppKit
import GhosttyKit

extension SurfaceView {
    /// Right-click only. We deliberately don't surface a menu on
    /// ⌃-left-click — libghostty's mouse pipeline already routes that
    /// to the running TUI, and intercepting it would break programs that
    /// bind ⌃-click themselves.
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

        // Forward the right-press to libghostty only when there is no
        // selection to protect. On a mouse-reporting surface (a TUI like
        // vim / htop / Claude) libghostty reports the press to the program
        // and, as a side effect, clears any shift-selection — which would
        // strip the Copy item exactly when the user reached for it. So when
        // a selection already exists we leave it untouched and just show
        // the menu; with no selection we let libghostty handle the press
        // (word-select under the cursor for the default context-menu
        // action; click-forwarding in a TUI), then re-read the selection
        // for the Copy gate below.
        if let surface, !ghostty_surface_has_selection(surface) {
            sendRightMousePressForMenu(with: event)
        }

        return SurfaceContextMenu.make(
            SurfaceContextMenuState(
                hasSelection: surface.map { ghostty_surface_has_selection($0) } ?? false,
                isInPane: paneID != nil,
                canRenamePane: canRenamePane?() == true,
                zoomAction: paneZoomAction?(),
                canMoveToNewTab: canMoveToNewTab?() == true,
                shortcut: { [keyboardSettings] command in
                    command.shortcut { keyboardSettings?().shortcut(for: $0) }
                }
            ),
            locale: resolvedAppLocale
        )
    }

    /// The app locale the host installed, for the text this view puts
    /// outside SwiftUI. A surface no host has wired never reaches the
    /// screen, so its fallback is never read.
    var resolvedAppLocale: Locale {
        appLocale?() ?? .current
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

    @objc func movePaneToNewTab(_ sender: Any?) {
        onRequestMoveToNewTab?()
    }

    @objc func renamePaneFromMenu(_ sender: Any?) {
        onRequestRenamePane?()
    }

    @objc func zoomPaneFromMenu(_ sender: Any?) {
        onRequestZoomAction?()
    }

    private func runSurfaceBinding(_ action: String) {
        guard let surface else { return }
        GhosttyFFI.performBindingAction(action, on: surface)
    }
}

/// What the right-click menu offers, read from the surface each time it
/// opens.
struct SurfaceContextMenuState {
    var hasSelection: Bool
    /// Find, split, and close act through callbacks the pane host
    /// installs. A surface outside any pane (the quick terminal) has none
    /// of them, so the menu leaves those items out rather than offer ones
    /// that do nothing.
    var isInPane: Bool
    var canRenamePane: Bool
    var zoomAction: PaneZoomAction?
    var canMoveToNewTab: Bool
    /// The key an item shows; see `MenuCommand`. The menu is built per
    /// right-click and dropped when it closes, so these keys answer only
    /// while it is open, and a keystroke made without it reaches the menu
    /// bar once.
    var shortcut: (MenuCommand) -> StoredShortcut?
}

/// Builds the terminal's right-click menu. Kept apart from the view so the
/// titles can be checked in a given language without a live surface. The
/// items carry no target: they travel the responder chain to the surface,
/// which `menu(for:)` has just made first responder.
@MainActor
enum SurfaceContextMenu {
    /// `locale` is the app locale: an AppKit menu is outside SwiftUI's
    /// environment, and would otherwise answer in the launch language.
    static func make(_ state: SurfaceContextMenuState, locale: Locale) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: LocalizedStringResource, _ action: Selector, _ command: MenuCommand? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title.resolved(in: locale), action: action, keyEquivalent: "")
            if let command {
                item.showShortcut(state.shortcut(command))
            }
            return item
        }

        if state.hasSelection {
            _ = add("Copy", #selector(SurfaceView.copy(_:)), .copy)
        }
        _ = add("Paste", #selector(SurfaceView.paste(_:)), .paste)

        menu.addItem(.separator())
        _ = add("Select All", #selector(SurfaceView.selectAll(_:)), .selectAll)
        _ = add("Clear", #selector(SurfaceView.clearScreen(_:)))

        menu.addItem(.separator())
        _ = add("Scroll to Top", #selector(SurfaceView.scrollToTop(_:)))
        _ = add("Scroll to Bottom", #selector(SurfaceView.scrollToBottom(_:)))

        guard state.isInPane else { return menu }

        menu.addItem(.separator())
        _ = add("Find…", #selector(SurfaceView.findInSurface(_:)), .find)
        if state.canRenamePane {
            add("Rename Pane…", #selector(SurfaceView.renamePaneFromMenu(_:)))
                .image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        }

        appendPaneActionItems(state, add: add, to: menu)
        return menu
    }

    /// Split / zoom / promote / close section — split out of `make` so the
    /// builder stays under the function-body-length lint cap.
    private static func appendPaneActionItems(
        _ state: SurfaceContextMenuState,
        add: (LocalizedStringResource, Selector, MenuCommand?) -> NSMenuItem,
        to menu: NSMenu
    ) {
        menu.addItem(.separator())
        add("Split Right", #selector(SurfaceView.splitRight(_:)), .splitRight).image = NSImage(
            systemSymbolName: "rectangle.righthalf.inset.filled",
            accessibilityDescription: nil
        )
        add("Split Down", #selector(SurfaceView.splitDown(_:)), .splitDown).image = NSImage(
            systemSymbolName: "rectangle.bottomhalf.inset.filled",
            accessibilityDescription: nil
        )

        if state.zoomAction != nil || state.canMoveToNewTab {
            menu.addItem(.separator())
        }
        if let zoomAction = state.zoomAction {
            let isZoom = zoomAction == .zoom
            add(isZoom ? "Zoom Pane" : "Unzoom Pane", #selector(SurfaceView.zoomPaneFromMenu(_:)), .togglePaneZoom)
                .image = NSImage(
                    systemSymbolName: isZoom ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                    accessibilityDescription: nil
                )
        }
        if state.canMoveToNewTab {
            add("Move Pane to New Tab", #selector(SurfaceView.movePaneToNewTab(_:)), nil).image = NSImage(
                systemSymbolName: "rectangle.split.2x1",
                accessibilityDescription: nil
            )
        }

        menu.addItem(.separator())
        add("Close Pane", #selector(SurfaceView.closePaneFromMenu(_:)), .closePane).image = NSImage(
            systemSymbolName: "xmark.square",
            accessibilityDescription: nil
        )
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
        case #selector(movePaneToNewTab(_:)):
            return surface != nil && canMoveToNewTab?() == true
        case #selector(renamePaneFromMenu(_:)):
            return canRenamePane?() == true
        case #selector(zoomPaneFromMenu(_:)):
            return surface != nil && paneZoomAction?() != nil
        default:
            return true
        }
    }
}
