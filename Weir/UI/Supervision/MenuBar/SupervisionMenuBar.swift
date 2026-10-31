// SupervisionMenuBar.swift
// Weir — the menu bar extra: the lamp that shows the attention state, and the Needs Attention rows with what acts in place.

import AppKit
import SwiftUI
import WeirDomain

/// The menu bar extra's label: the lamp lit by the attention state, in the
/// title bar pill's tone (`MenuBarLabelModel`).
struct SupervisionMenuBarLabel: View {
    let state: AppState

    var body: some View {
        MenuBarLampImage(model: MenuBarLabelModel(state.attentionQueue.queue.counts()))
            .equatable()
    }
}

/// The lamp as one image. The menu bar takes one image or text for its
/// item, not a composed view, and draws a template in its own text color,
/// which drops color (https://developer.apple.com/forums/thread/726565).
/// Every lamp is a template, so it sits in the bar's own ink beside the
/// system's and the other apps' icons; an amber disc stood out from all of
/// them, louder than a wait deserves. The shape alone carries the state:
/// the app's mark stays whole, and a badge at its corner says the rest, a
/// dot for unread turns and an exclamation mark for what blocks on the
/// person. The drawing is `design/app-icons/menubar-*.svg`, in the same points.
/// Equatable on what it draws, so the queue changing without the lamp or
/// the count does not draw it again.
struct MenuBarLampImage: View, Equatable {
    let model: MenuBarLabelModel
    @Environment(\.locale) private var locale

    var body: some View {
        let label = model.accessibilityLabel(locale: locale)
        let image = Self.image(model.lamp)
        // The status item reads the image's own description; the label
        // covers SwiftUI's accessibility tree.
        image.accessibilityDescription = label
        return Image(nsImage: image)
            .accessibilityLabel(Text(verbatim: label))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
    }

    /// The lamp, drawn by a handler rather than from a bitmap, so each
    /// screen draws it at its own scale and no menu bar shows it blurred.
    /// One size for every lamp, with room for the badge even when there is
    /// none, so the item keeps its width as the state changes.
    static func image(_ lamp: MenuBarLabelModel.Lamp) -> NSImage {
        let image = NSImage(size: WeirLayout.Supervision.menuBarLampImageSize, flipped: true) { _ in
            // A template keeps only the alpha: black draws in the menu
            // bar's text color, whatever its appearance.
            NSColor.black.set()
            tile().fill()
            // What we cut out shows the bar's ground in either appearance.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            markLines().stroke()
            NSBezierPath(rect: NSRect(x: 4.5, y: 10.3, width: 3.2, height: 3.2)).fill()
            switch lamp {
            case .off:
                break
            case .unread:
                circle(centerX: 17, centerY: 13.5, radius: 4.3).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                circle(centerX: 17, centerY: 13.5, radius: 2.9).fill()
            case .blocking:
                circle(centerX: 16.5, centerY: 12.5, radius: 6.2).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                let badge = circle(centerX: 16.5, centerY: 12.5, radius: 5)
                badge.append(NSBezierPath(rect: NSRect(x: 15.6, y: 9.3, width: 1.8, height: 3.9)))
                badge.append(NSBezierPath(rect: NSRect(x: 15.6, y: 14.1, width: 1.8, height: 1.6)))
                badge.windingRule = .evenOdd
                badge.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The rounded square the mark is cut out of.
    private static func tile() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 5.5, y: 1.5))
        path.line(to: NSPoint(x: 12.5, y: 1.5))
        path.curve(to: NSPoint(x: 16.5, y: 5.5), controlPoint1: NSPoint(x: 15, y: 1.5), controlPoint2: NSPoint(x: 16.5, y: 3))
        path.line(to: NSPoint(x: 16.5, y: 12.5))
        path.curve(to: NSPoint(x: 12.5, y: 16.5), controlPoint1: NSPoint(x: 16.5, y: 15), controlPoint2: NSPoint(x: 15, y: 16.5))
        path.line(to: NSPoint(x: 5.5, y: 16.5))
        path.curve(to: NSPoint(x: 1.5, y: 12.5), controlPoint1: NSPoint(x: 3, y: 16.5), controlPoint2: NSPoint(x: 1.5, y: 15))
        path.line(to: NSPoint(x: 1.5, y: 5.5))
        path.curve(to: NSPoint(x: 5.5, y: 1.5), controlPoint1: NSPoint(x: 1.5, y: 3), controlPoint2: NSPoint(x: 3, y: 1.5))
        path.close()
        return path
    }

    /// The mark's two flows, which share one center so the gap between
    /// them stays even around the bend.
    private static func markLines() -> NSBezierPath {
        let center = NSPoint(x: 8.75, y: 9.25)
        let path = NSBezierPath()
        path.lineWidth = 1.7
        for (radius, endX) in [(CGFloat(3.9), CGFloat(12.65)), (1, 9.75)] {
            path.move(to: NSPoint(x: 4.5, y: center.y - radius))
            path.line(to: NSPoint(x: center.x, y: center.y - radius))
            path.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: 0, clockwise: false)
            path.line(to: NSPoint(x: endX, y: 13.5))
        }
        return path
    }

    private static func circle(centerX: CGFloat, centerY: CGFloat, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2))
    }
}

/// The menu bar extra's window: the Needs Attention list's heading and
/// rows, in its order, and under a row what settles it without opening
/// Weir. It opens with no row lit, as a system menu does; ↓ and ↑
/// enter the list at its top or bottom and move, and the pointer lights the
/// row under it. Tab goes through a row's buttons (those under it, then its
/// Answer…) and back to the row; ⇧Tab from the first row (or an empty list,
/// or no row) goes up to the heading's ⋯; Return opens the row, presses the
/// button, or opens the ⋯; ⌘, and ⌘Q do what the app's do; and Escape
/// closes the menu, as the system's does.
///
/// The window wears the system's appearance, not the app's: the menu bar
/// is the system's chrome, and the menus beside this one follow the OS
/// setting (`MenuBarAppearance`). The app pins `NSApp.appearance` to its
/// own preference, which every window inherits; this one is handed the
/// system's as it comes to its window, and again as the system switches.
struct SupervisionMenuBarContent: View {
    let state: AppState
    @Environment(\.locale) private var locale
    @Environment(\.openWindow) private var openWindow
    @State private var itemsHeight: CGFloat = 0
    @State private var menuWindow = MenuBarActions.MenuWindow()
    @State private var selection = NeedsAttentionListSelection(rows: [], opening: .nothing)
    /// Counts the keyboard's moves, so the list scrolls to the row the keys
    /// reached and not to the one the pointer lit: scrolling under the
    /// pointer would light another row, and scroll again.
    @State private var keyboardMoves = 0
    @State private var isSystemDark = MenuBarAppearance.isSystemDark()
    @State private var moreMenuOpener = PopUpMenuOpener()
    @FocusState private var isFocused: Bool

    private func model(now: Date) -> (list: NeedsAttentionListModel, menu: MenuBarModel) {
        let registry = state.windowRegistry
        // Outside any window: no item is in another, and ⌘-click opens a
        // window for an item of a project none shows.
        let list = NeedsAttentionListModel(
            queue: state.attentionQueue.queue,
            session: state.session,
            approvals: state.approvalPresentation,
            windowProjectID: nil,
            projectsInWindows: registry.projectsShown(besides: nil, in: state.session),
            locale: locale
        )
        let menu = MenuBarModel(
            rows: list.rows,
            request: { id in MenuBarActions.request(for: id, state: state) },
            canResume: { id in MenuBarActions.canResume(id, state: state) },
            resetNotice: { id in MenuBarActions.resetNotice(id, state: state, now: now) },
            isInPane: { id in MenuBarActions.isInPane(id, state: state) }
        )
        return (list, menu)
    }

    var body: some View {
        // Drawn again as each usage limit resets, as the decision bar is: a
        // stop's words and buttons change then while the menu is open.
        let (list, menu) = model(now: max(state.usageLimitResetSync?.resetPassedAt ?? .distantPast, Date()))
        content(list: list, menu: menu)
    }

    private func content(list: NeedsAttentionListModel, menu: MenuBarModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NeedsAttentionHeading(list.heading, wordsInset: WeirLayout.Supervision.menuBarWordsInset) {
                MenuBarMoreMenu(
                    opener: moreMenuOpener,
                    isKeyboardOn: selection.isOnHeading,
                    onOpenWeir: { MenuBarActions.openWeir(state: state, menuWindow: menuWindow) },
                    onOpenSettings: openSettings,
                    onQuit: quit
                )
            }
            NeedsAttentionCapacityWarning(
                isNearCapacity: state.approvalPresentation.isNearCapacity,
                wordsInset: WeirLayout.Supervision.menuBarWordsInset
            )
            if menu.items.isEmpty {
                // The Needs Attention list's empty state, under the heading
                // that names the list.
                SupervisionEmptyState(.nothingNeedsAttention, size: .compact)
            } else {
                rows(menu.items)
            }
        }
        .frame(width: WeirLayout.Supervision.needsAttentionListWidth, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        // The list holds the keyboard, so VoiceOver reads the list: its
        // heading when it opens, and the row the keys are on as they move.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(list.heading))
        .accessibilityValue(Text(verbatim: selection.spokenRow(in: list.rows)))
        .onKeyPress(.downArrow) {
            selection.move(forward: true, in: list.rows)
            keyboardMoves += 1
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection.move(forward: false, in: list.rows)
            keyboardMoves += 1
            return .handled
        }
        .onKeyPress(keys: [.tab, .backTab]) { press in
            let item = menu.items.first { $0.id == selection.rowID }
            selection.nextControl(count: item?.keyboardActionCount ?? 0, backward: press.isBackTab, in: list.rows)
            return .handled
        }
        .onKeyPress(.return) {
            if selection.isOnHeading {
                moreMenuOpener.open()
                return .handled
            }
            guard let item = menu.items.first(where: { $0.id == selection.rowID }),
                  let control = item.control(at: selection.actionIndex)
            else { return .ignored }
            press(control, on: item)
            return .handled
        }
        // The app's ⌘, and ⌘Q, which do not reach the app's menu while the
        // menu bar's window holds the keyboard and Weir is not active.
        .onKeyPress(keys: [",", "q"]) { press in
            guard press.modifiers == .command else { return .ignored }
            if press.key == "," {
                openSettings()
            } else {
                quit()
            }
            return .handled
        }
        .onAppear {
            selection = NeedsAttentionListSelection(rows: list.rows, opening: .nothing)
            KeyboardHandoff.afterResponderSettles { isFocused = true }
        }
        // The window is kept between openings: each time it shows again,
        // the list opens afresh with no row lit.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, window === menuWindow.window,
                  window.occlusionState.contains(.visible)
            else { return }
            selection = NeedsAttentionListSelection(rows: list.rows, opening: .nothing)
        }
        // The system can post this before it has written the new style;
        // reading on the next turn sees it written.
        .onReceive(DistributedNotificationCenter.default().publisher(for: MenuBarAppearance.themeChangedNotification)) { _ in
            Task { @MainActor in
                isSystemDark = MenuBarAppearance.isSystemDark()
            }
        }
        .onChange(of: isSystemDark) { _, _ in
            applySystemAppearance(to: menuWindow.window)
        }
        .onChange(of: menu.items) { previous, current in
            func controls(in items: [MenuBarModel.Item]) -> (AttentionItemID) -> [MenuBarModel.Control] {
                { id in items.first { $0.id == id }?.controls ?? [] }
            }
            selection.reconcile(
                previous: previous.map(\.row),
                current: current.map(\.row),
                previousControls: controls(in: previous),
                currentControls: controls(in: current)
            )
        }
        .background(WindowAccessor { [menuWindow] window in
            menuWindow.window = window
            applySystemAppearance(to: window)
        })
        // The system's menu: its material ground, a fill in its labels' ink
        // under the row the keys or the pointer are on, and the system's
        // labels for the words (`PopoverSurface.systemMenu`).
        .environment(\.popoverSurface, .systemMenu)
        // The primary button and the focus ring take the person's accent
        // from the settings: the extra's window is not under the main
        // windows' environment that carries them. Not
        // `weirAccentPropagated`'s tint: the menu keeps the system's
        // controls and its own accent highlight.
        .environment(state.settingsStore)
        // SwiftUI resolves every color here, the tokens' dynamic `NSColor`s
        // included, against its own color scheme, which the extra's hosting
        // view takes from the app's pinned appearance rather than from the
        // window we hand the system's: told only the window, the glass
        // went dark while the light theme's grays stayed on it. The scheme
        // is set with the window, from the same reading.
        .environment(\.colorScheme, Self.colorScheme(isSystemDark: isSystemDark))
    }

    /// The scheme the menu's content draws in: the system's
    /// (`MenuBarAppearance`), the same as its window's.
    static func colorScheme(isSystemDark: Bool) -> ColorScheme {
        isSystemDark ? .dark : .light
    }

    /// Hands `window` the system's appearance (`MenuBarAppearance`), over
    /// the app's that it inherits from `NSApp.appearance`.
    private func applySystemAppearance(to window: NSWindow?) {
        window?.appearance = NSAppearance(named: isSystemDark ? .darkAqua : .aqua)
    }

    private func openSettings() {
        MenuBarActions.openSettings(menuWindow: menuWindow) { openWindow(id: WeirApp.settingsWindowID) }
    }

    private func quit() {
        MenuBarActions.quit(menuWindow: menuWindow)
    }

    private func rows(_ items: [MenuBarModel.Item]) -> some View {
        ScrollViewReader { proxy in
            // A scroll view has no height of its own to give the menu's
            // window, which sizes to its content: it takes the rows'
            // height, up to a limit past which they scroll.
            ScrollView {
                // The wait time steps once a minute ("just now", then 1m,
                // 2m…), so a finer tick would only redraw the same text.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: WeirLayout.Supervision.menuBarRowSpacing) {
                        ForEach(items) { item in
                            let isSelected = item.id == selection.rowID && !selection.isOnHeading
                            MenuBarRow(
                                item: item,
                                now: context.date,
                                isSelected: isSelected,
                                selectedControl: isSelected ? item.control(at: selection.actionIndex) : nil,
                                press: { press($0, on: item) },
                                open: { opening in
                                    selection.select(item.id)
                                    MenuBarActions.open(item.id, opening: opening, state: state, menuWindow: menuWindow)
                                },
                                hover: { isHovering in
                                    if isHovering {
                                        selection.select(item.id)
                                    } else {
                                        selection.deselect(item.id)
                                    }
                                }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(WeirLayout.Supervision.menuBarListInset)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { itemsHeight = $0 }
            }
            .frame(height: min(itemsHeight, WeirLayout.Supervision.menuBarListMaxHeight))
            .onChange(of: keyboardMoves) { _, _ in
                guard let id = selection.rowID else { return }
                proxy.scrollTo(id)
            }
        }
    }

    /// What a press on `control` of `item` does (`MenuBarModel.Control`).
    private func press(_ control: MenuBarModel.Control, on item: MenuBarModel.Item) {
        switch control {
        case .row:
            MenuBarActions.open(item.id, opening: .returnKey, state: state, menuWindow: menuWindow)
        case let .inPlace(action):
            MenuBarActions.perform(action, on: item.id, state: state)
        case let .rowAction(action):
            MenuBarActions.perform(action, on: item.id, state: state, menuWindow: menuWindow)
        }
    }
}

/// One item: the list's row, and under it, outside the row's fill, the
/// command in full, why the menu does not answer it, and the buttons that
/// settle it in place, left-aligned on one line with only the primary in
/// color, and Answer… at that line's end: every control of the item on one
/// line, in the order Tab goes through them, and every row's fill and time
/// as wide as the others'. The row's fill marks only what opening the row
/// goes to; VoiceOver reaches each button under it as its own element.
private struct MenuBarRow: View {
    let item: MenuBarModel.Item
    let now: Date
    let isSelected: Bool
    /// What the keyboard is on in this row; `nil` when it is elsewhere.
    let selectedControl: MenuBarModel.Control?
    let press: (MenuBarModel.Control) -> Void
    let open: (NeedsAttentionListOpening) -> Void
    /// The pointer came over the item (`true`), the row or what is under
    /// it, or left it.
    let hover: (Bool) -> Void
    @Environment(\.popoverSurface.ground) private var ground
    @Environment(\.popoverSurface.ink) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeedsAttentionRowView(
                row: item.row,
                now: now,
                isSelected: isSelected,
                openHint: hint,
                onOpen: open
            )
            if hasInPlace {
                inPlace
            }
        }
        // The pointer over the buttons under the row is still on its item,
        // so the row stays lit and says which item they settle; only
        // leaving the item darkens it.
        .contentShape(Rectangle())
        .onHover(perform: hover)
    }

    private var hasInPlace: Bool {
        item.command != nil || item.note != nil || !item.actions.isEmpty || item.row.action != nil
    }

    /// In line with the row's words, past its state glyph.
    private var inPlace: some View {
        VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceSnug) {
            if let command = item.command {
                Text(verbatim: command)
                    .font(.supervision(.meta, design: .monospaced))
                    .foregroundStyle(ink.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(WeirLayout.Supervision.menuBarCommandInsets)
                    .background(
                        RoundedRectangle(cornerRadius: WeirLayout.Supervision.menuBarCommandCornerRadius, style: .continuous)
                            .fill(ground.well.color)
                    )
            }
            if let note = item.note {
                Text(Self.text(note))
                    .font(.supervision(.meta))
                    .foregroundStyle(ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.actions.isEmpty || item.row.action != nil {
                HStack(spacing: WeirLayout.Supervision.spaceS) {
                    ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                        button(action)
                    }
                    Spacer(minLength: 0)
                    if let action = item.row.action {
                        rowActionButton(action)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WeirLayout.Supervision.menuBarInPlaceInsets)
    }

    @ViewBuilder
    private func button(_ action: MenuBarModel.Action) -> some View {
        let button = Button(Self.title(action)) { press(.inPlace(action)) }
        Group {
            if action.isPrimary {
                button.buttonStyle(SupervisionPrimaryButtonStyle())
            } else if action.isRefusal {
                button.buttonStyle(.supervisionSecondary(tone: .refusal))
            } else {
                button.buttonStyle(.supervisionSecondary)
            }
        }
        // The keyboard's place on the button, shown like a focused
        // control, since the menu holds the focus.
        .supervisionFocusRing(isFocused: selectedControl == .inPlace(action), cornerRadius: WeirLayout.Supervision.buttonCornerRadius)
        // The control Return presses, said as the ring shows it.
        .accessibilityAddTraits(selectedControl == .inPlace(action) ? .isSelected : [])
    }

    private func rowActionButton(_ action: NeedsAttentionListModel.RowAction) -> some View {
        Button(NeedsAttentionRowView.title(action)) { press(.rowAction(action)) }
            .buttonStyle(.supervisionSecondary)
            .supervisionFocusRing(
                isFocused: selectedControl == .rowAction(action),
                cornerRadius: WeirLayout.Supervision.buttonCornerRadius
            )
            .accessibilityAddTraits(selectedControl == .rowAction(action) ? .isSelected : [])
    }

    private var hint: LocalizedStringResource {
        switch item.openHint {
        case .goesToPane:
            LocalizedStringResource(
                "Goes to this pane in Weir",
                comment: "Menu bar row accessibility hint: Weir comes to the front at the item's pane"
            )
        case .goesToPaneToAnswerInTerminal:
            LocalizedStringResource(
                "Goes to this pane in Weir to answer in the terminal",
                comment: "Menu bar row accessibility hint on a request: Weir shows its pane, which hands it to the terminal"
            )
        case .opensCard:
            LocalizedStringResource(
                "Opens the approval card",
                comment: "Menu bar row accessibility hint on a request with no pane: Weir opens its approval card"
            )
        }
    }

    private static func text(_ note: MenuBarModel.Note) -> LocalizedStringResource {
        switch note {
        case .highImpact:
            LocalizedStringResource(
                "High-impact command. Review it in Weir.",
                comment: "Menu bar: an approval the menu does not allow, because the command is high-impact"
            )
        case .tooLong:
            LocalizedStringResource(
                "Long command. View it in full in Weir.",
                comment: "Menu bar: an approval the menu does not allow, because the command is too long or on several lines"
            )
        case .notShownWhole:
            LocalizedStringResource(
                "Some characters can’t be shown. View it in full in Weir.",
                comment: "Menu bar: an approval the menu does not allow, as the short command has characters it cannot show as they run"
            )
        case .sending:
            LocalizedStringResource(
                "Sending your answer…",
                comment: "Menu bar: the person's decision is on its way to the agent"
            )
        case .sendFailed:
            "Couldn’t send your answer. Try again."
        case .answered:
            "Already answered."
        case .handedToTerminal:
            "Handed to the terminal. Answer in that pane."
        case .timedOut:
            "Timed out. Answer in the terminal."
        case .resetNoticeRequested:
            LocalizedStringResource(
                "You’ll be notified when it resets.",
                comment: "Decision bar and menu bar on a usage limit stop: a notification will arrive when the limit resets"
            )
        }
    }

    private static func title(_ action: MenuBarModel.Action) -> LocalizedStringResource {
        switch action {
        case .allowOnce:
            "Allow once"
        case .deny:
            "Deny"
        case .resume:
            "Resume Same Conversation"
        case .notifyAtReset:
            LocalizedStringResource(
                "Notify When It Resets",
                comment: "Decision bar on a usage limit stop: asks for a notification when the limit resets"
            )
        }
    }
}

/// The heading's ⋯: what the menu bar is the only way in to while Weir
/// is not active, since the menu does not make it active and the app's own
/// ⌘, and ⌘Q do not reach it then. Kept in the heading rather than a row
/// at the foot, so nothing stands under the rows. An AppKit menu
/// (`PopUpMenuButton`), so the menu's own keyboard can open it on Return
/// (`opener`) and its items show the keys the menu answers.
private struct MenuBarMoreMenu: View {
    let opener: PopUpMenuOpener
    /// The menu's keyboard is on the ⋯, which the list, holding the focus,
    /// draws as a focused control.
    let isKeyboardOn: Bool
    let onOpenWeir: @MainActor () -> Void
    let onOpenSettings: @MainActor () -> Void
    let onQuit: @MainActor () -> Void
    @Environment(\.popoverSurface.ink) private var ink

    var body: some View {
        PopUpMenuButton(
            title: LocalizedStringResource(
                "More Actions",
                comment: "Tooltip and VoiceOver label of a ⋯ menu (the decision bar, the notification history, the menu bar item)"
            )
        ) {
            [
                .item(PopUpMenuItem(title: "Open Weir", perform: onOpenWeir)),
                .item(PopUpMenuItem(
                    title: "Settings…",
                    shortcut: StoredShortcut(key: ",", modifiers: [.command]),
                    perform: onOpenSettings
                )),
                .separator,
                .item(PopUpMenuItem(
                    title: LocalizedStringResource(
                        "menuBar.quit",
                        defaultValue: "Quit Weir",
                        comment: "Menu bar item's ⋯ menu: quits the app, as the app menu's Quit does"
                    ),
                    shortcut: StoredShortcut(key: "q", modifiers: [.command]),
                    perform: onQuit
                ))
            ]
        } label: {
            Image(systemName: "ellipsis")
                .font(.supervision(.label, weight: .medium))
                .foregroundStyle(ink.muted)
                // The whole square takes the click, not only the dots, and
                // keeps the heading's line as tall as the list's.
                .frame(
                    width: WeirLayout.Supervision.secondaryButtonHeight,
                    height: WeirLayout.Supervision.secondaryButtonHeight
                )
                .contentShape(Rectangle())
        }
        .opened(by: opener)
        .fixedSize()
        .supervisionFocusRing(isFocused: isKeyboardOn, cornerRadius: WeirLayout.Supervision.buttonCornerRadius)
        // The control Return presses, said as the ring shows it.
        .accessibilityAddTraits(isKeyboardOn ? .isSelected : [])
    }
}
