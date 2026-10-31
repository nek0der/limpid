// PopUpMenuButton.swift
// Weir — a menu button that opens an AppKit menu built at the moment it
// opens, for the "⋯" menus whose items show keyboard shortcuts.

import AppKit
import SwiftUI

/// One row of a `PopUpMenuButton`'s menu.
enum PopUpMenuEntry {
    case item(PopUpMenuItem)
    case separator
    /// A heading over the items after it, as the system draws one
    /// (`NSMenuItem.sectionHeader`): words already resolved, never chosen.
    case header(String)
    /// A heading with more to say than its words: a second line, and an
    /// image before it (a conversation's badge over its turns, in the
    /// review's scope menu).
    case heading(PopUpMenuHeading)
    /// An item that opens a menu of its own, `entries`, rather than doing
    /// something: what a long menu folds away (the review's viewed
    /// conversations).
    case submenu(PopUpMenuItem, [PopUpMenuEntry])
}

/// A section heading of a `PopUpMenuButton`'s menu with a second line and
/// an image (`PopUpMenuEntry.heading`). Never chosen.
struct PopUpMenuHeading {
    let title: String
    /// Under the title, in the menu's smaller secondary face; `nil` for
    /// none.
    var subtitle: String?
    /// Before the title; `nil` for none. Drawn once the menu opens, in its
    /// appearance (`PopUpMenu.make`).
    var image: (@MainActor () -> NSImage?)?
    /// What VoiceOver reads for the heading, where its lines say more
    /// together than the title does; `nil` reads the title.
    var accessibilityLabel: String?
}

/// An item in a `PopUpMenuButton`'s menu.
struct PopUpMenuItem {
    /// What the item is called: a resource resolved when the menu opens, in
    /// the language the SwiftUI tree is showing (`PopUpMenu.make(_:locale:)`),
    /// or words the caller already resolved (an agent's name and count).
    enum Title {
        case resource(LocalizedStringResource)
        case verbatim(String)

        /// The words, in `locale` for a resource.
        func resolved(in locale: Locale) -> String {
            switch self {
            case let .resource(resource): resource.resolved(in: locale)
            case let .verbatim(text): text
            }
        }
    }

    let name: Title
    /// A second line under the name, in the menu's smaller secondary
    /// face: a conversation's state under its name in the changes panel's
    /// filter. `nil` for the one-line item most menus have.
    var subtitle: String?
    var systemImage: String?
    /// An image drawn into the title once the menu opens, in place of
    /// `systemImage`: a conversation's badge before its name, as its
    /// heading in the review's scope menu carries it. `nil` for none.
    var image: (@MainActor () -> NSImage?)?
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
    /// Whether the item is the one chosen, drawn with the menu's checkmark.
    var isChecked = false
    /// The item's tooltip, `nil` for none. AppKit shows it on a disabled
    /// item too, which is where it says why the item cannot be chosen.
    var help: Title?
    /// What VoiceOver calls the item, where the title says more than its
    /// name; `nil` reads the title.
    var accessibilityLabel: String?
    /// What VoiceOver reads after the item's name, `nil` for nothing.
    var accessibilityValue: String?
    let perform: @MainActor () -> Void

    init(
        title: LocalizedStringResource,
        systemImage: String? = nil,
        shortcut: StoredShortcut? = nil,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        help: LocalizedStringResource? = nil,
        perform: @escaping @MainActor () -> Void
    ) {
        name = .resource(title)
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.help = help.map(Title.resource)
        self.perform = perform
    }

    init(
        verbatim title: String,
        subtitle: String? = nil,
        isChecked: Bool = false,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        image: (@MainActor () -> NSImage?)? = nil,
        perform: @escaping @MainActor () -> Void
    ) {
        name = .verbatim(title)
        self.subtitle = subtitle
        self.image = image
        self.isChecked = isChecked
        self.help = help.map(Title.verbatim)
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.perform = perform
    }
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
///
/// The tooltip is the trigger's own `NSView.toolTip`: AppKit shows it for
/// the view under the pointer, which the trigger always is, being laid over
/// the label. A SwiftUI `.help` on a `Menu`'s label rarely shows, as the
/// menu's own control takes the pointer and has no tooltip of its own.
struct PopUpMenuButton<Label: View>: View {
    private let title: PopUpMenuItem.Title
    /// The tooltip, when it says more than the title; the title otherwise.
    private let help: String?
    /// What VoiceOver reads after the title, `nil` for nothing.
    private let value: String?
    let entries: () -> [PopUpMenuEntry]
    /// Opens the menu from outside the button; `nil` for a button only a
    /// click, its own keys, or VoiceOver opens.
    private var opener: PopUpMenuOpener?
    /// Whether ⇥ reaches the button under Full Keyboard Access
    /// (`keyboardFocusable(_:)`).
    private var allowsKeyboardFocus = true
    @ViewBuilder let label: () -> Label

    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled

    init(title: LocalizedStringResource, entries: @escaping () -> [PopUpMenuEntry], @ViewBuilder label: @escaping () -> Label) {
        self.title = .resource(title)
        help = nil
        value = nil
        self.entries = entries
        self.label = label
    }

    /// A button named by words already resolved, with a tooltip and a
    /// VoiceOver value of its own: the changes panel's conversation
    /// filter and the review's scope menu, whose value says what is shown.
    init(
        verbatim title: String,
        help: String?,
        value: String?,
        entries: @escaping () -> [PopUpMenuEntry],
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.title = .verbatim(title)
        self.help = help
        self.value = value
        self.entries = entries
        self.label = label
    }

    var body: some View {
        let locale = locale
        let name = title.resolved(in: locale)
        label()
            // The trigger above it is the accessibility element.
            .accessibilityHidden(true)
            .overlay {
                PopUpMenuTrigger(
                    title: name,
                    help: help,
                    value: value,
                    isEnabled: isEnabled,
                    allowsKeyboardFocus: allowsKeyboardFocus,
                    opener: opener
                ) {
                    PopUpMenu.make(entries(), locale: locale)
                }
            }
    }
}

extension PopUpMenuButton {
    /// The button, opened also by `opener`: a list that keeps the keyboard
    /// itself (the menu bar extra's) opens its heading's ⋯ on Return.
    func opened(by opener: PopUpMenuOpener) -> Self {
        var button = self
        button.opener = opener
        return button
    }

    /// The button kept out of the ⇥ order under Full Keyboard Access when
    /// `isFocusable` is `false`, as `.focusable(false)` keeps a SwiftUI
    /// button: where ⇥ belongs to the terminal's TUI (the decision
    /// bar). A click and VoiceOver still open it.
    func keyboardFocusable(_ isFocusable: Bool) -> Self {
        var button = self
        button.allowsKeyboardFocus = isFocusable
        return button
    }
}

/// Opens a `PopUpMenuButton`'s menu from code, as a click on it would.
@MainActor
final class PopUpMenuOpener {
    /// `nil` until the button is drawn, or once it is gone.
    weak var trigger: PopUpMenuTriggerView?

    /// On the next turn, so the key press that asked for it returns before
    /// the menu's tracking takes over.
    func open() {
        DispatchQueue.main.async { [weak self] in
            self?.trigger?.open()
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
            case let .header(title): menu.addItem(.sectionHeader(title: title))
            case let .heading(heading): menu.addItem(item(for: heading))
            case let .item(item): menu.addItem(PopUpMenuActionItem(item, locale: locale))
            case let .submenu(item, entries):
                let parent = PopUpMenuActionItem(item, locale: locale)
                // An item with a submenu opens it; it has nothing to run.
                parent.action = nil
                parent.submenu = make(entries, locale: locale)
                menu.addItem(parent)
            }
        }
        return menu
    }

    /// A section heading with its second line and image: the system's
    /// heading item, with the two lines in the faces a two-line item uses.
    ///
    /// The image goes inside the title rather than in the item's image
    /// column, and the name carries the label color: a heading is never
    /// chosen, so AppKit draws it as a disabled item, fading an item image
    /// and an uncolored title until the heading reads as an item that
    /// cannot be used. An attributed title is drawn in the colors it
    /// carries, so the badge keeps its own and the name the primary color;
    /// only the second line stays secondary.
    private static func item(for heading: PopUpMenuHeading) -> NSMenuItem {
        let item = NSMenuItem.sectionHeader(title: heading.title)
        let image = heading.image?()
        if image != nil || heading.subtitle != nil {
            item.attributedTitle = title(
                heading.title,
                subtitle: heading.subtitle,
                after: image,
                font: .boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                color: .labelColor
            )
        }
        if let label = heading.accessibilityLabel {
            item.setAccessibilityLabel(label)
        }
        return item
    }

    /// `title` in `font` after `image`, with the second line under the
    /// name rather than under the image: a line separator keeps both lines
    /// one paragraph, so the second takes the indent the image and its
    /// space leave. `color` `nil` leaves the title to the menu's own color,
    /// which fades it on a disabled item.
    static func title(
        _ title: String,
        subtitle: String?,
        after image: NSImage?,
        font: NSFont,
        color: NSColor?
    ) -> NSAttributedString {
        let lines = NSMutableAttributedString()
        if let image {
            let attachment = NSTextAttachment()
            attachment.image = image
            // Centered on the name's capitals, as an item image sits beside
            // its title.
            attachment.bounds = CGRect(
                x: 0,
                y: ((font.capHeight - image.size.height) / 2).rounded(),
                width: image.size.width,
                height: image.size.height
            )
            lines.append(NSAttributedString(attachment: attachment))
            lines.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        let indent = lines.size().width
        var titleAttributes: [NSAttributedString.Key: Any] = [.font: font]
        titleAttributes[.foregroundColor] = color
        lines.append(NSAttributedString(string: title, attributes: titleAttributes))
        if let subtitle {
            lines.append(NSAttributedString(string: "\u{2028}" + subtitle, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = indent
        lines.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: lines.length))
        return lines
    }
}

private struct PopUpMenuTrigger: NSViewRepresentable {
    let title: String
    let help: String?
    let value: String?
    let isEnabled: Bool
    let allowsKeyboardFocus: Bool
    let opener: PopUpMenuOpener?
    let makeMenu: @MainActor () -> NSMenu

    func makeNSView(context _: Context) -> PopUpMenuTriggerView {
        PopUpMenuTriggerView()
    }

    func updateNSView(_ view: PopUpMenuTriggerView, context _: Context) {
        view.title = title
        view.help = help
        view.value = value
        view.isEnabled = isEnabled
        view.allowsKeyboardFocus = allowsKeyboardFocus
        view.makeMenu = makeMenu
        opener?.trigger = view
    }
}

/// The clickable, focusable, accessible part of a `PopUpMenuButton`, laid
/// over its SwiftUI label. AppKit so it can open the menu on mouse-down, as
/// a pop-up button does, and say it is a menu button.
@MainActor
final class PopUpMenuTriggerView: NSView {
    var title = "" {
        didSet { toolTip = help ?? title }
    }

    /// The tooltip, when it is not the title. Optional, as most menus are
    /// said by their title alone.
    var help: String? {
        didSet { toolTip = help ?? title }
    }

    /// What VoiceOver reads after the title. Optional, as most menus have
    /// nothing to add.
    var value: String?

    /// Off as the SwiftUI tree around it is: no click, key, or VoiceOver
    /// press opens the menu, and the keyboard neither reaches it nor stays
    /// on it.
    var isEnabled = true {
        didSet {
            guard !isEnabled, let window, window.firstResponder === self else { return }
            window.makeFirstResponder(nil)
        }
    }

    /// Whether ⇥ reaches the button under Full Keyboard Access; `false`
    /// where ⇥ belongs to the terminal (`PopUpMenuButton.keyboardFocusable`).
    var allowsKeyboardFocus = true {
        didSet {
            guard !allowsKeyboardFocus, let window, window.firstResponder === self else { return }
            window.makeFirstResponder(nil)
        }
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
        guard isEnabled, let menu = makeMenu?() else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: bounds.height + WeirLayout.popUpMenuGap),
            in: self
        )
    }

    // MARK: - Keyboard

    // Reachable with Tab when Full Keyboard Access is on, as a button is,
    // unless kept out of the Tab order (`allowsKeyboardFocus`), and
    // otherwise never the first responder, so a click leaves the keyboard
    // with the terminal.

    override var acceptsFirstResponder: Bool {
        Self.takesKeyboard(
            isFullKeyboardAccessOn: NSApp.isFullKeyboardAccessEnabled,
            isEnabled: isEnabled,
            allowsKeyboardFocus: allowsKeyboardFocus
        )
    }

    override var canBecomeKeyView: Bool {
        acceptsFirstResponder
    }

    /// Whether the trigger takes the keyboard: only with Full Keyboard
    /// Access on, enabled, and allowed into the Tab order.
    nonisolated static func takesKeyboard(isFullKeyboardAccessOn: Bool, isEnabled: Bool, allowsKeyboardFocus: Bool) -> Bool {
        isFullKeyboardAccessOn && isEnabled && allowsKeyboardFocus
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

    /// Nothing where a value is read: the tooltip says what the title and
    /// the value already said, and VoiceOver would read it twice.
    override func accessibilityHelp() -> String? {
        value == nil ? help ?? title : nil
    }

    override func accessibilityValue() -> Any? {
        value
    }

    override func isAccessibilityEnabled() -> Bool {
        isEnabled
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
        guard isEnabled else { return false }
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
        super.init(title: item.name.resolved(in: locale), action: #selector(run(_:)), keyEquivalent: "")
        target = self
        // A drawn image goes inside the title, as a heading's does: AppKit
        // draws no image set on an item of this menu, so a conversation's
        // badge and identity bar would not show.
        if let drawn = item.image?() {
            attributedTitle = PopUpMenu.title(
                item.name.resolved(in: locale),
                subtitle: item.subtitle,
                after: drawn,
                font: .menuFont(ofSize: 0),
                color: nil
            )
        } else if let subtitle = item.subtitle {
            attributedTitle = Self.twoLines(item.name.resolved(in: locale), subtitle)
        }
        isEnabled = item.isEnabled
        state = item.isChecked ? .on : .off
        toolTip = item.help?.resolved(in: locale)
        if let label = item.accessibilityLabel {
            setAccessibilityLabel(label)
        }
        if let value = item.accessibilityValue {
            setAccessibilityValue(value)
        }
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

    /// The name over its second line, the line in the menu's small face
    /// and the secondary label color, as the system's two-line items read.
    static func twoLines(_ title: String, _ subtitle: String) -> NSAttributedString {
        let lines = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        lines.append(NSAttributedString(string: "\n" + subtitle, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        return lines
    }
}
