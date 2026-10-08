// PopUpMenuButton.swift
// Limpid — a menu button that opens an AppKit menu built at the moment it
// opens, for the "⋯" menus whose items show keyboard shortcuts.

import AppKit
import SwiftUI

/// One row of a `PopUpMenuButton`'s menu.
enum PopUpMenuEntry {
    case item(PopUpMenuItem)
    case separator
}

/// An item in a `PopUpMenuButton`'s menu.
struct PopUpMenuItem {
    /// Resolved when the menu opens, in the language the SwiftUI tree is
    /// showing; see `PopUpMenu.make(_:locale:)`.
    let title: LocalizedStringResource
    var systemImage: String?
    /// The key shown beside the title; `MenuCommand` says which items have
    /// one.
    var shortcut: StoredShortcut?
    var isEnabled = true
    /// What `Button(role: .destructive)` said in the SwiftUI menu this item
    /// replaces. It changes nothing on screen, by design: SwiftUI draws a
    /// destructive button in a macOS menu exactly like any other (we checked
    /// the `NSMenuItem` it makes: same title, same image, nothing set for
    /// accessibility), and macOS menus never color an item to warn.
    var isDestructive = false
    let perform: @MainActor () -> Void
}

/// A button that opens a menu of `entries`, built when it opens, so every
/// item reads the state and the shortcuts current at that moment.
///
/// Not a SwiftUI `Menu`. Once a `Menu` has been opened, SwiftUI keeps its
/// items' `.keyboardShortcut`s live in the window while the menu is closed,
/// and the window answers a key equivalent before the menu bar does. A pane
/// header's "Close Pane" showing ⌘W would then take the next ⌘W and close
/// its own pane rather than the focused one. An AppKit menu built per open
/// answers its keys only while it is tracking, so the shortcut is shown and
/// a keystroke made with no menu open still goes to the menu bar, the one
/// place each shortcut is live.
///
/// It keeps what the `Menu` did otherwise. The menu opens on mouse-down and
/// its tracking takes the rest of the press, so a gesture on a view around
/// the button sees no click and no drag. VoiceOver hears a menu button named
/// `title`, which is also the tooltip. And the titles follow `\.locale`, so
/// switching the app's language in Settings changes them at once.
struct PopUpMenuButton<Label: View>: View {
    let title: LocalizedStringResource
    let entries: () -> [PopUpMenuEntry]
    @ViewBuilder let label: () -> Label

    @Environment(\.locale) private var locale

    var body: some View {
        let locale = locale
        label()
            // The trigger above it is the accessibility element.
            .accessibilityHidden(true)
            .overlay {
                PopUpMenuTrigger(title: title.resolved(in: locale)) {
                    PopUpMenu.make(entries(), locale: locale)
                }
            }
    }
}

/// Builds the menu a `PopUpMenuButton` opens.
@MainActor
enum PopUpMenu {
    static func make(_ entries: [PopUpMenuEntry], locale: Locale) -> NSMenu {
        let menu = NSMenu()
        // Each item carries its own enabled state; without this AppKit would
        // enable every item whose target answers the action, which all do.
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator: menu.addItem(.separator())
            case let .item(item): menu.addItem(PopUpMenuActionItem(item, locale: locale))
            }
        }
        return menu
    }
}

private struct PopUpMenuTrigger: NSViewRepresentable {
    let title: String
    let makeMenu: @MainActor () -> NSMenu

    func makeNSView(context _: Context) -> PopUpMenuTriggerView {
        PopUpMenuTriggerView()
    }

    func updateNSView(_ view: PopUpMenuTriggerView, context _: Context) {
        view.title = title
        view.makeMenu = makeMenu
    }
}

/// The clickable, focusable, accessible part of a `PopUpMenuButton`, laid
/// over its SwiftUI label. AppKit so it can open the menu on mouse-down, as
/// a pop-up button does, and say it is a menu button.
@MainActor
final class PopUpMenuTriggerView: NSView {
    var title = "" {
        didSet { toolTip = title }
    }

    /// Nil only before the representable's first update; a click then opens
    /// nothing.
    var makeMenu: (@MainActor () -> NSMenu)?

    /// Flipped so the menu's origin is measured down from the button's top.
    override var isFlipped: Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        open()
    }

    func open() {
        guard let menu = makeMenu?() else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: bounds.height + LimpidLayout.popUpMenuGap),
            in: self
        )
    }

    // MARK: - Keyboard

    // Reachable with Tab when Full Keyboard Access is on, as a button is,
    // and otherwise never the first responder, so a click leaves the
    // keyboard with the terminal.

    override var acceptsFirstResponder: Bool {
        NSApp.isFullKeyboardAccessEnabled
    }

    override var canBecomeKeyView: Bool {
        NSApp.isFullKeyboardAccessEnabled
    }

    override func keyDown(with event: NSEvent) {
        switch event.namedKey {
        case .space, .return: open()
        default: super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect {
        bounds
    }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .menuButton
    }

    override func accessibilityTitle() -> String? {
        title
    }

    override func accessibilityHelp() -> String? {
        title
    }

    override func accessibilityPerformPress() -> Bool {
        openAfterReply()
    }

    override func accessibilityPerformShowMenu() -> Bool {
        openAfterReply()
    }

    /// The menu tracks until it closes; opening it on the next turn lets the
    /// accessibility request that asked for it return first.
    private func openAfterReply() -> Bool {
        DispatchQueue.main.async { [weak self] in
            self?.open()
        }
        return true
    }
}

/// A menu item that runs a closure. It is its own target: `NSMenuItem`
/// holds its target weakly, and the menu holding the item keeps both alive
/// for as long as the menu is open.
@MainActor
final class PopUpMenuActionItem: NSMenuItem {
    private let perform: @MainActor () -> Void
    let isDestructive: Bool

    init(_ item: PopUpMenuItem, locale: Locale) {
        perform = item.perform
        isDestructive = item.isDestructive
        super.init(title: item.title.resolved(in: locale), action: #selector(run(_:)), keyEquivalent: "")
        target = self
        isEnabled = item.isEnabled
        image = item.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        showShortcut(item.shortcut)
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run(_: Any?) {
        perform()
    }
}
