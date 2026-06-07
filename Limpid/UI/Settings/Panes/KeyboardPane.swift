// KeyboardPane.swift
// Limpid — Settings → Keyboard. Every `LimpidShortcutAction` shows
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
    @State private var recordingAction: LimpidShortcutAction?

    /// Confirmation alert state for "Restore Defaults". We don't
    /// wipe overrides on first click because every action falling
    /// back to its default at once is hard to undo by hand.
    @State private var showingResetConfirm = false

    /// Stored separately so the literal stays under SwiftLint's
    /// line-length cap. The exact string is the `Localizable.xcstrings`
    /// key — splitting it across source lines would change the key.
    private let footerKey: LocalizedStringKey =
        // swiftlint:disable:next line_length
        "Click a shortcut to rebind it. Press ⎋ to cancel, ⌫ to clear back to default. ⌘1–⌘9 and ⌘⌃1–⌘⌃9 are reserved for tab and section jumps."

    /// True when at least one action has a user override on it —
    /// disables the Restore button when there's nothing to undo.
    private var hasAnyOverride: Bool {
        !store.settings.keyboard.overrides.isEmpty
    }

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Keyboard") {
            ForEach(LimpidShortcutCategory.allCases) { category in
                let actions = LimpidShortcutAction.allCases
                    .filter { $0.category == category }
                Section {
                    ForEach(actions) { action in
                        ShortcutRow(
                            action: action,
                            keyboard: $store.settings.keyboard,
                            recordingAction: $recordingAction
                        )
                    }
                } header: {
                    Text(category.sectionTitle)
                }
            }
            Section {
                // Left-aligned destructive button, matching the
                // shape Advanced > Restore All Defaults uses so the
                // two reset affordances feel consistent.
                Button(role: .destructive) {
                    showingResetConfirm = true
                } label: {
                    Text("Restore Defaults")
                }
                .disabled(!hasAnyOverride)
            } footer: {
                Text(footerKey)
            }
        }
        .confirmationDialog(
            "Restore all keyboard shortcuts to defaults?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                store.settings.keyboard.overrides.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Title already says "restore to defaults" — the message
            // only needs to flag the irreversible part. Anything
            // longer reads like an over-explanation.
            Text("This cannot be undone.")
        }
    }
}

// MARK: - Row

/// One action + its current shortcut + a recorder button. Tapping
/// the trigger area starts capture; the next non-modifier keypress
/// is validated and either stored or rejected with a row-local
/// warning. `⎋` cancels; `⌫` resets to default.
private struct ShortcutRow: View {
    let action: LimpidShortcutAction
    @Binding var keyboard: KeyboardSettings
    @Binding var recordingAction: LimpidShortcutAction?

    @State private var rejection: ShortcutValidation?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                // Fixed slot widths so the recorder button's trailing
                // edge lands at the same x across every row regardless
                // of whether the override / reset affordance is showing
                // and regardless of the recorded glyph's width.
                HStack(spacing: 8) {
                    ShortcutRecorder(
                        action: action,
                        keyboard: $keyboard,
                        recordingAction: $recordingAction,
                        rejection: $rejection
                    )
                    .frame(width: 170, alignment: .trailing)

                    ZStack {
                        if keyboard.overrides[action.rawValue] != nil {
                            Button {
                                keyboard.resetOverride(for: action)
                                rejection = nil
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .help("Reset to default")
                        }
                    }
                    .frame(width: 18, alignment: .center)
                }
            } label: {
                Text(action.localizedTitle)
            }
            if let rejection {
                Text(rejectionMessage(for: rejection))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 4)
            }
        }
    }

    private func rejectionMessage(for rejection: ShortcutValidation) -> String {
        switch rejection {
        case .ok:
            return ""
        case let .conflict(other):
            // Interpolate into a single localized template so
            // translators can reorder (ja wants the noun before
            // the verb: "X に既に割当済み" rather than "X に X を").
            let name = String(localized: other.localizedTitle)
            return String(localized: "Already bound to \(name)")
        case .reserved:
            return String(localized: "Reserved by Limpid (⌘1–⌘9, ⌘⌃1–⌘⌃9)")
        case .missingModifier:
            return String(localized: "Shortcut must include ⌘, ⌥, ⌃, or ⇧")
        }
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
    let action: LimpidShortcutAction
    @Binding var keyboard: KeyboardSettings
    @Binding var recordingAction: LimpidShortcutAction?
    @Binding var rejection: ShortcutValidation?

    @Environment(\.limpidAccent) private var accent
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
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
            Text(label)
                .font(.system(.body, design: .default).monospacedDigit())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            isRecording
                                ? accent.opacity(0.2)
                                : Color.secondary.opacity(0.12)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isRecording ? accent : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        // `.onGeometryChange` fires on any geometric change — size OR
        // position. The previous `GeometryReader { .onChange(of: proxy.size) }`
        // shape only fired when size changed, so scrolling Settings
        // moved the row without re-publishing the frame. The mouse
        // monitor's click-outside test then misclassified clicks: a
        // visible click on the recorder pill could be treated as
        // outside (cancels recording) or vice versa. Mirrors the
        // working pattern in `ToolbarPaletteField`.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { _, newValue in
            frameInPane = newValue
        }
        .onChange(of: recordingAction) { _, new in
            // Monitor lifecycle is driven by the shared
            // `recordingAction` binding so two rows can't briefly
            // both hold monitors during a same-tick click. Each row
            // installs only when it sees its own action win the
            // binding, and tears down when anyone else (including
            // `nil`) takes over.
            if new == action {
                installKeyMonitor()
                installMouseMonitor()
            } else {
                teardownMonitors()
            }
        }
        .onDisappear {
            if isRecording { recordingAction = nil }
            teardownMonitors()
        }
    }

    private var label: String {
        if isRecording { return String(localized: "Press a key…") }
        return displayedShortcut?.displayString ?? String(localized: "Unbound")
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
        // Esc cancels without changing anything.
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        // Backspace / Delete clears the override (back to default).
        if event.keyCode == 51 {
            keyboard.resetOverride(for: action)
            rejection = nil
            stopRecording()
            return
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
        let result = keyboard.validate(shortcut, for: action)
        switch result {
        case .ok:
            keyboard.setOverride(shortcut, for: action)
            rejection = nil
            stopRecording()
        case .conflict, .reserved, .missingModifier:
            rejection = result
            // Stay recording so the user can press another combo
            // without an extra click; Esc still cancels via
            // `handleKey`.
        }
    }
}
