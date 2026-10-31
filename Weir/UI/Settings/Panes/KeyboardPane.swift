// KeyboardPane.swift
// Weir — Settings → Keyboard. Every `WeirShortcutAction` shows
// up as one row grouped by category; on commit the recorder runs
// `KeyboardSettings.validate` and either saves or surfaces a
// row-local warning. The menu bar and (where applicable)
// libghostty both read back from the same store.

import AppKit
import SwiftUI

struct KeyboardPane: View {
    @Environment(SettingsStore.self) private var store

    /// Single source of truth for which row (if any) is currently
    /// armed. Lives at the pane level so when the user clicks a
    /// second row, the first row observes the change and tears its
    /// monitor down — without this, both rows' `addLocalMonitorForEvents`
    /// handlers fight over the next keystroke and the first-installed
    /// monitor wins, leaving the visibly-focused row dead.
    @State private var recordingAction: WeirShortcutAction?

    /// Confirmation alert state for "Restore Defaults". We don't
    /// wipe overrides on first click because every action falling
    /// back to its default at once is hard to undo by hand.
    @State private var showingResetConfirm = false

    /// Same storage `SettingsScene` selects the visible section from, so
    /// the quick-terminal row can switch to that pane.
    @AppStorage(SettingsSection.lastSectionDefaultsKey) private var selectedSectionRaw = SettingsSection.keyboard.rawValue

    /// Stored separately so the literal stays under SwiftLint's
    /// line-length cap. The exact string is the `Localizable.xcstrings`
    /// key — splitting it across source lines would change the key.
    private let footerKey: LocalizedStringKey =
        // swiftlint:disable:next line_length
        "Click a shortcut to change it. Press ⎋ to cancel, or ⌫ to restore the default. To leave one unassigned, choose Unassign from its ⋯ menu. ⌘⏎ is kept for the main button under an agent’s pane, and ⌘1–9 and ⌃⌘1–9 for moving between tabs and worktrees."

    /// True when Restore has something to undo: an override, a retired
    /// binding, or a default the person unassigned. A default given up for
    /// the quick terminal's hotkey is not one, since Restore leaves the
    /// hotkey where it is.
    private var hasAnyOverride: Bool {
        let keyboard = store.settings.keyboard
        return !keyboard.overrides.isEmpty || !keyboard.retired.isEmpty || !keyboard.unassigned.isEmpty
    }

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Keyboard", section: .keyboard) {
            if store.settings.keyboard.migrationNotice != nil {
                KeyboardMigrationSection(
                    keyboard: $store.settings.keyboard,
                    quickTerminalHotKey: store.settings.quickTerminal.hotKey
                )
            }
            ForEach(WeirShortcutCategory.allCases) { category in
                let actions = WeirShortcutAction.allCases
                    .filter { $0.category == category }
                Section {
                    ForEach(actions) { action in
                        ShortcutRow(
                            action: action,
                            keyboard: $store.settings.keyboard,
                            quickTerminalHotKey: store.settings.quickTerminal.hotKey,
                            recordingAction: $recordingAction
                        )
                        .settingsSearchTarget(SettingsSearchCatalog.shortcutID(action))
                    }
                } header: {
                    Text(category.sectionTitle)
                }
            }
            // The quick terminal's hotkey is recorded in its own pane: it is
            // system-wide, has no menu item, and follows different rules
            // (⌘ or ⌃ required, shortcuts macOS has enabled refused).
            // Listing it here read-only keeps the one place people look for
            // shortcuts complete without mixing those rules into the rows
            // above.
            Section {
                HStack(spacing: 12) {
                    Text("Quick Terminal hotkey")
                    Spacer(minLength: 12)
                    // Same width and pill as `ShortcutRow`, so the hotkey
                    // lines up with the shortcuts above; the chevron inside
                    // the pill says it opens another pane instead of
                    // recording here.
                    Button {
                        selectedSectionRaw = SettingsSection.quickTerminal.rawValue
                    } label: {
                        HStack(spacing: 4) {
                            Text(display: store.settings.quickTerminal.hotKey.map { .verbatim($0.displayString) } ?? .localized("Unbound"))
                                .font(.system(.body, design: .default).monospacedDigit())
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .center)
                            Image(systemName: "chevron.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .settingsRecorderPill()
                    }
                    .buttonStyle(.plain)
                    .frame(width: WeirLayout.settingsRecorderWidth, alignment: .trailing)
                    .help("Open Quick Terminal settings")
                    .accessibilityLabel(Text("Open Quick Terminal settings"))
                }
                .settingsControlRow(controlHeight: WeirLayout.settingsRecorderPillHeight)
                .settingsSearchTarget(SettingsSearchCatalog.keyboardQuickTerminalHotKey.id)
            } header: {
                Text("System-wide")
            } footer: {
                SettingsFootnote("Active in every app, not only Weir. Change it in Quick Terminal settings.")
            }
            Section {
                // The same trailing row Advanced > Restore Default Settings
                // uses, so the two reset buttons sit in one place.
                SettingsButtonRow {
                    Button(role: .destructive) {
                        showingResetConfirm = true
                    } label: {
                        Text("Restore Defaults")
                    }
                    .disabled(!hasAnyOverride)
                }
                .settingsSearchTarget(SettingsSearchCatalog.keyboardRestoreDefaults.id)
            } footer: {
                SettingsFootnote(footerKey)
            }
        }
        .confirmationDialog(
            "Restore all keyboard shortcuts to defaults?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                store.settings.keyboard.restoreDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Title already says "restore to defaults" — the message
            // only needs to flag the irreversible part. Anything
            // longer reads like an over-explanation.
            Text("This can’t be undone.")
        }
    }
}

// MARK: - After the update

/// What the update to the supervision window's shortcuts changed:
/// bindings that no longer apply, kept until the person discards them, and
/// new actions left without a default because the person's own binding
/// held its keys.
private struct KeyboardMigrationSection: View {
    @Binding var keyboard: KeyboardSettings
    let quickTerminalHotKey: StoredShortcut?
    @Environment(\.locale) private var locale

    /// Kept whole on one line: the literal is the `Localizable.xcstrings`
    /// key, and splitting it would change the key.
    private static let footerKey: LocalizedStringKey =
        // swiftlint:disable:next line_length
        "Your own shortcuts were kept. New shortcuts whose default keys you had already assigned start unassigned, and shortcuts that no longer apply stay here until you discard them."

    var body: some View {
        Section {
            ForEach(KeyboardMigrationRows.rows(keyboard, quickTerminalHotKey: quickTerminalHotKey, locale: locale)) { row in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.title)
                        if let detail = row.detail {
                            Text(verbatim: detail)
                                .font(.caption)
                                .foregroundStyle(SettingsFootnote.style.color)
                        }
                    }
                    if case let .retired(rawValue) = row.kind {
                        Spacer(minLength: 12)
                        Button("Discard") {
                            keyboard.discardRetired(rawValue)
                        }
                        .accessibilityLabel(Text("Discard \(row.title)"))
                    }
                }
            }
        } header: {
            Text("Changed by the Update")
        } footer: {
            SettingsFootnote(Self.footerKey)
        }
    }
}

// MARK: - Row

/// One action + its current shortcut + a recorder button. Tapping
/// the trigger area starts capture; the next non-modifier keypress
/// is validated and either stored or rejected with a row-local
/// warning. `⎋` cancels; `⌫` restores the default. The ⋯ menu and the
/// context menu unassign it.
private struct ShortcutRow: View {
    let action: WeirShortcutAction
    @Binding var keyboard: KeyboardSettings
    /// Carbon takes the quick terminal's global hotkey before the menu bar
    /// sees it, so the recorder refuses it.
    let quickTerminalHotKey: StoredShortcut?
    @Binding var recordingAction: WeirShortcutAction?

    @State private var rejection: ShortcutValidation?

    /// Why this action may hold the same keys as another
    /// (`WeirShortcutAction.sharesKeys`); `nil` for every other action.
    private var sharedKeysNote: LocalizedStringResource? {
        switch action {
        case .moveProjectUp, .moveProjectDown:
            LocalizedStringResource(
                "Only while the sidebar has focus. Elsewhere, the same keys move between panes.",
                comment: "Settings → Keyboard, hint of Move Project Up and Down: why they share keys"
            )
        case .focusPaneUp, .focusPaneDown:
            LocalizedStringResource(
                "While the sidebar has focus, the same keys move a project.",
                comment: "Settings → Keyboard, hint of Focus Pane Above and Below: why they share keys"
            )
        default: nil
        }
    }

    var body: some View {
        // A custom row (see `settingsControlRow`) with the rejection
        // message as a second line under the label, so the row keeps the
        // height of its neighbors while no message is showing.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.localizedTitle)
                    // Two pairs of rows show the same keys (the sidebar's
                    // and the panes' moves); this says why they do not clash.
                    .help(sharedKeysNote.map { Text($0) } ?? Text(verbatim: ""))
                    .accessibilityHint(sharedKeysNote.map { Text($0) } ?? Text(verbatim: ""))
                if let message = rejection?.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(SupervisionTokens.stoppedText.color)
                }
            }
            Spacer(minLength: 12)
            // Fixed widths so the pill's trailing edge lands at the
            // form's control edge on every row, regardless of whether the
            // reset affordance is showing and regardless of the recorded
            // glyph's width. The row's menu and the reset button take fixed
            // slots before the pill, so the pills line up with the quick
            // terminal's hotkey row below.
            HStack(spacing: 8) {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: WeirLayout.settingsRecorderAccessoryWidth, alignment: .center)
                .help(Text("More for \(Text(action.localizedTitle))"))
                .accessibilityLabel(Text("More for \(Text(action.localizedTitle))"))
                ZStack {
                    // Also for a default that was unassigned, which shows
                    // "Unassigned" and has no override to drop.
                    if canRestore {
                        Button {
                            restoreDefault()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Restore Default")
                        // Named by its action, as a value row's ↺ is, so
                        // VoiceOver's list of buttons tells the rows apart.
                        .accessibilityLabel(Text(RestoreDefaultSlot.label(for: action.localizedTitle)))
                    }
                }
                .frame(width: WeirLayout.settingsRecorderAccessoryWidth, alignment: .center)
                ShortcutRecorder(
                    action: action,
                    keyboard: $keyboard,
                    quickTerminalHotKey: quickTerminalHotKey,
                    recordingAction: $recordingAction,
                    rejection: $rejection
                )
                .frame(width: WeirLayout.settingsRecorderWidth, alignment: .trailing)
            }
        }
        .settingsControlRow(controlHeight: WeirLayout.settingsRecorderPillHeight)
        .contextMenu { menuItems }
    }

    private var canRestore: Bool {
        keyboard.canRestoreDefault(action)
    }

    /// Unassigning is here rather than on a key: ⌫ restores the default,
    /// as in Quick Terminal (`ShortcutRecorderKey`).
    @ViewBuilder private var menuItems: some View {
        Button("Unassign") {
            keyboard.unassign(action)
            rejection = nil
        }
        .disabled(keyboard.shortcut(for: action) == nil)
        Button("Restore Default") {
            restoreDefault()
        }
        .disabled(!canRestore)
    }

    private func restoreDefault() {
        keyboard.restoreDefault(for: action)
        rejection = nil
    }
}

// MARK: - Recorder

/// Borderless button that swaps into "recording" mode on click. In
/// recording mode it installs a local `NSEvent` monitor so the next
/// non-modifier keypress is validated and committed.
///
/// "Currently recording" is owned by the parent pane (`recordingAction`)
/// so only one row at a time is armed; this row's local `monitor`
/// state tracks the AppKit handle that needs to be removed.
private struct ShortcutRecorder: View {
    let action: WeirShortcutAction
    @Binding var keyboard: KeyboardSettings
    let quickTerminalHotKey: StoredShortcut?
    @Binding var recordingAction: WeirShortcutAction?
    @Binding var rejection: ShortcutValidation?

    @Environment(QuickTerminalHotKeyCenter.self) private var hotKeyCenter: QuickTerminalHotKeyCenter?
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    /// This row's hold on the quick terminal's global hotkey while it
    /// records. `nil` when not recording or when Settings runs without a
    /// hotkey center (previews).
    @State private var hotKeySuspension: QuickTerminalHotKeyCenter.Suspension?
    /// Button frame in SwiftUI's `.global` space (window content
    /// view, top-left origin). The mouse monitor converts AppKit's
    /// window-coordinate click into this same space before deciding
    /// whether the click counts as "outside".
    @State private var frameInPane: CGRect = .zero

    private var isRecording: Bool {
        recordingAction == action
    }

    private var displayedShortcut: StoredShortcut? {
        keyboard.shortcut(for: action)
    }

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Text(display: label)
                .font(.system(.body, design: .default).monospacedDigit())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .settingsRecorderPill(isRecording: isRecording)
        }
        .buttonStyle(.plain)
        // The row is an `HStack`, not `LabeledContent`, so the action's
        // title is not attached to the button for accessibility; set it
        // here and report the shortcut as the value, the same way the
        // Quick Terminal recorder does.
        .accessibilityLabel(Text(action.localizedTitle))
        .accessibilityValue(Text(display: label))
        // `.onGeometryChange` fires on any geometric change — size OR
        // position. The previous `GeometryReader { .onChange(of: proxy.size) }`
        // shape only fired when size changed, so scrolling Settings
        // moved the row without re-publishing the frame. The mouse
        // monitor's click-outside test then misclassified clicks: a
        // visible click on the recorder pill could be treated as
        // outside (cancels recording) or vice versa. Mirrors the
        // working pattern in `ToolbarPaletteField`.
        // Measured only while this row records, the one row whose frame
        // the mouse monitor reads; in the background, so the row keeps its
        // identity as recording starts and stops.
        .background {
            if isRecording {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { _, newValue in
                        frameInPane = newValue
                    }
            }
        }
        .onChange(of: recordingAction) { _, new in
            // Monitor lifecycle is driven by the shared
            // `recordingAction` binding so two rows can't briefly
            // both hold monitors during a same-tick click. Each row
            // installs only when it sees its own action win the
            // binding, and tears down when anyone else (including
            // `nil`) takes over.
            if new == action {
                suspendQuickTerminalHotKey()
                installKeyMonitor()
                installMouseMonitor()
            } else {
                teardownMonitors()
            }
        }
        .stopsShortcutRecordingOnFocusLoss(isRecording: isRecording) {
            stopRecording()
        }
        .onDisappear {
            if isRecording {
                recordingAction = nil
            }
            teardownMonitors()
        }
    }

    private var label: DisplayText {
        if isRecording {
            return .localized("Press a key…")
        }
        return displayedShortcut.map { .verbatim($0.displayString) } ?? .localized("Unbound")
    }

    // MARK: - Monitor lifecycle

    @MainActor
    private func startRecording() {
        // Clear any stale rejection from a prior attempt, then flip
        // the shared binding. `.onChange(of: recordingAction)` is
        // what actually installs our monitors — keeping that flow in
        // one place means the "previous row, claim, install" order
        // can never race.
        rejection = nil
        recordingAction = action
    }

    @MainActor
    private func stopRecording() {
        // Symmetric with startRecording: clear the binding and let
        // `.onChange` tear our monitors down for us.
        recordingAction = nil
    }

    @MainActor
    private func teardownMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let hotKeySuspension {
            hotKeyCenter?.resume(hotKeySuspension)
            self.hotKeySuspension = nil
        }
    }

    /// Carbon takes a registered global hotkey before our key monitor
    /// sees it, so without this, pressing the quick terminal's hotkey
    /// would toggle the panel instead of reaching `commit(_:)` and its
    /// `.quickTerminalConflict` message. Released in `teardownMonitors()`,
    /// which every way out of recording goes through.
    @MainActor
    private func suspendQuickTerminalHotKey() {
        guard hotKeySuspension == nil else { return }
        hotKeySuspension = hotKeyCenter?.suspend()
    }

    @MainActor
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event)
            // Swallow the event so the keystroke we just recorded
            // doesn't also reach the focused control behind us.
            return nil
        }
    }

    @MainActor
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            // Convert AppKit's window-coord click (bottom-left, Y up)
            // into SwiftUI `.global` (top-left, Y down) so we can
            // compare against `frameInPane`. Without a window we
            // conservatively cancel.
            guard let window = event.window,
                  let contentView = window.contentView
            else {
                stopRecording()
                return event
            }
            let appkitPoint = contentView.convert(event.locationInWindow, from: nil)
            let swiftUIPoint = CGPoint(
                x: appkitPoint.x,
                y: contentView.bounds.height - appkitPoint.y
            )
            if !frameInPane.contains(swiftUIPoint) {
                stopRecording()
            }
            return event
        }
    }

    // MARK: - Keystroke handling

    @MainActor
    private func handleKey(_ event: NSEvent) {
        switch ShortcutRecorderKey.meaning(of: event.namedKey) {
        case .cancel:
            stopRecording()
            return
        case .restoreDefault:
            keyboard.restoreDefault(for: action)
            rejection = nil
            stopRecording()
            return
        case .record:
            break
        }
        guard let captured = StoredShortcut.capture(from: event) else {
            stopRecording()
            return
        }
        commit(captured)
    }

    /// Run validation; commit on `.ok`, stay armed on rejection.
    /// Keeping the recorder open after an invalid keystroke means
    /// the user retries without re-clicking — and the visible glyph
    /// stays on "Press a key…" so the red message doesn't look
    /// like it's accusing the previously-saved shortcut. Xcode's
    /// own shortcut recorder behaves the same way.
    @MainActor
    private func commit(_ shortcut: StoredShortcut) {
        let result = keyboard.validate(shortcut, for: action, quickTerminalHotKey: quickTerminalHotKey)
        switch result {
        case .ok:
            keyboard.setOverride(shortcut, for: action)
            rejection = nil
            stopRecording()
        case .conflict, .conflictWithPair, .keptBySidebar, .reserved, .missingModifier, .quickTerminalConflict:
            rejection = result
            // Stay recording so the user can press another combo
            // without an extra click; Esc still cancels via
            // `handleKey`.
        }
    }
}

// MARK: - Focus loss

extension View {
    /// Ends a shortcut recording when the Settings window stops being key
    /// or Weir stops being the active app. The recorder's local key
    /// monitor only sees keystrokes sent to our windows, so a recording
    /// left armed would keep the quick terminal's global hotkey suspended
    /// with nothing able to finish it. Any window resigning key counts:
    /// while a recorder is armed, the Settings window is the key window.
    func stopsShortcutRecordingOnFocusLoss(
        isRecording: Bool,
        stop: @escaping @MainActor () -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if isRecording {
                stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if isRecording {
                stop()
            }
        }
    }
}
