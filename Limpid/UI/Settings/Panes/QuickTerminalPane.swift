// QuickTerminalPane.swift
// Limpid — Settings → Quick Terminal: the global hotkey, where the panel
// appears, how large it is, and whether it hides on focus loss.

import AppKit
import SwiftUI

struct QuickTerminalPane: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Quick Terminal", section: .quickTerminal) {
            Section {
                QuickTerminalHotKeyRow(
                    quickTerminal: $store.settings.quickTerminal,
                    keyboard: store.settings.keyboard
                )
                .settingsSearchTarget(SettingsSearchCatalog.quickTerminalHotKey.id)
            } header: {
                Text("Hotkey")
            } footer: {
                SettingsFootnote(
                    """
                    Active in every app, not only Limpid. Click to record a hotkey; press ⎋ to cancel \
                    or ⌫ to restore the default, which is no hotkey.
                    """
                )
            }

            Section {
                Picker("Position", selection: $store.settings.quickTerminal.position) {
                    SettingsDefaultMark.title(Text("Top"), value: QuickTerminalPosition.top, of: \.quickTerminal.position)
                        .tag(QuickTerminalPosition.top)
                    SettingsDefaultMark.title(Text("Bottom"), value: QuickTerminalPosition.bottom, of: \.quickTerminal.position)
                        .tag(QuickTerminalPosition.bottom)
                    SettingsDefaultMark.title(Text("Left"), value: QuickTerminalPosition.left, of: \.quickTerminal.position)
                        .tag(QuickTerminalPosition.left)
                    SettingsDefaultMark.title(Text("Right"), value: QuickTerminalPosition.right, of: \.quickTerminal.position)
                        .tag(QuickTerminalPosition.right)
                    SettingsDefaultMark.title(Text("Center"), value: QuickTerminalPosition.center, of: \.quickTerminal.position)
                        .tag(QuickTerminalPosition.center)
                }
                .settingsSearchTarget(SettingsSearchCatalog.quickTerminalPosition.id)
                // Named for what it measures at this position, so the
                // percentage says of what without a footnote.
                Picker(
                    store.settings.quickTerminal.position.isSizedByWidth ? LocalizedStringKey("Width") : LocalizedStringKey("Height"),
                    selection: $store.settings.quickTerminal.sizePercent
                ) {
                    ForEach(QuickTerminalSettings.allowedSizePercents, id: \.self) { percent in
                        SettingsDefaultMark.title(
                            Text(Double(percent) / 100, format: .percent),
                            value: percent,
                            of: \.quickTerminal.sizePercent
                        )
                        .tag(percent)
                    }
                }
                .settingsSearchTarget(SettingsSearchCatalog.quickTerminalSize.id)
            } header: {
                Text("Layout")
            }

            Section {
                SettingsToggle("Hide when focus leaves", isOn: $store.settings.quickTerminal.hidesOnFocusLoss)
                    .settingsSearchTarget(SettingsSearchCatalog.quickTerminalHidesOnFocusLoss.id)
            } header: {
                Text("Behavior")
            }
        }
    }
}

// MARK: - Hotkey row

/// The recorder plus its restore button, with whatever stops the hotkey from
/// working shown underneath.
private struct QuickTerminalHotKeyRow: View {
    @Binding var quickTerminal: QuickTerminalSettings
    let keyboard: KeyboardSettings

    @Environment(QuickTerminalHotKeyCenter.self) private var hotKeyCenter: QuickTerminalHotKeyCenter?
    @State private var rejection: QuickTerminalHotKeyValidation?

    var body: some View {
        // A custom row (see `settingsControlRow`) with the message as a
        // second line under the label, matching `ShortcutRow`.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show or hide")
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(SupervisionTokens.stoppedText.color)
                } else if let warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(SupervisionTokens.waitingText.color)
                }
            }
            Spacer(minLength: 12)
            // Same widths and controls as the Keyboard pane's rows: ↺ takes
            // a fixed slot before the pill so the pill's trailing edge lines
            // up with the form's other controls. The default is no hotkey,
            // so restoring it and unassigning leave the same thing.
            HStack(spacing: 8) {
                ZStack {
                    if quickTerminal.hotKey != nil {
                        Button {
                            unassign()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Restore Default")
                        .accessibilityLabel(Text(RestoreDefaultSlot.label(for: "Quick Terminal hotkey")))
                    }
                }
                .frame(width: LimpidLayout.settingsRecorderAccessoryWidth, alignment: .center)
                QuickTerminalHotKeyRecorder(
                    quickTerminal: $quickTerminal,
                    keyboard: keyboard,
                    rejection: $rejection
                )
                .frame(width: LimpidLayout.settingsRecorderWidth, alignment: .trailing)
            }
        }
        .settingsControlRow(controlHeight: LimpidLayout.settingsRecorderPillHeight)
        .contextMenu {
            Button("Unassign") {
                unassign()
            }
            .disabled(quickTerminal.hotKey == nil)
        }
    }

    private func unassign() {
        quickTerminal.hotKey = nil
        rejection = nil
    }

    /// Caution about the saved hotkey that does not stop it from working.
    /// Only shown when there is no error, which is the more urgent line.
    private var warning: LocalizedStringResource? {
        guard let hotKey = quickTerminal.hotKey,
              QuickTerminalSettings.mayOverlapAppCommands(hotKey)
        else { return nil }
        return QuickTerminalSettings.appCommandOverlapWarning
    }

    /// A recorder rejection wins over a registration problem: it describes
    /// the key the user just pressed, not the one already saved.
    private var message: LocalizedStringResource? {
        rejection?.message ?? hotKeyCenter?.problem?.message
    }
}

// MARK: - Recorder

/// Button that records the next key combination. Same interaction as the
/// Keyboard pane's recorder: a local key monitor takes the next keyDown, a
/// mouse monitor cancels on a click elsewhere, ⎋ cancels, ⌫ restores the default.
private struct QuickTerminalHotKeyRecorder: View {
    @Binding var quickTerminal: QuickTerminalSettings
    let keyboard: KeyboardSettings
    @Binding var rejection: QuickTerminalHotKeyValidation?

    @Environment(QuickTerminalHotKeyCenter.self) private var hotKeyCenter: QuickTerminalHotKeyCenter?
    @State private var isRecording = false
    /// Our hold on the global hotkey while recording. `nil` when not
    /// recording or when Settings runs without a hotkey center (previews).
    @State private var suspension: QuickTerminalHotKeyCenter.Suspension?
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    /// Button frame in SwiftUI's `.global` space, for the click-outside test.
    @State private var frameInPane: CGRect = .zero

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
        .accessibilityLabel(Text("Quick Terminal hotkey"))
        .accessibilityValue(Text(display: label))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { _, newValue in
            frameInPane = newValue
        }
        .stopsShortcutRecordingOnFocusLoss(isRecording: isRecording) {
            stopRecording()
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var label: DisplayText {
        if isRecording {
            return .localized("Press a key…")
        }
        return quickTerminal.hotKey.map { .verbatim($0.displayString) } ?? .localized("Unbound")
    }

    private func startRecording() {
        guard !isRecording else { return }
        rejection = nil
        isRecording = true
        // Carbon would take the current hotkey before our key monitor sees
        // it, toggling the panel instead of recording.
        if suspension == nil {
            suspension = hotKeyCenter?.suspend()
        }
        installMonitors()
    }

    /// Every way out of recording ends here, including the view going
    /// away, so the suspension is always released.
    private func stopRecording() {
        teardownMonitors()
        if let suspension {
            hotKeyCenter?.resume(suspension)
            self.suspension = nil
        }
        isRecording = false
    }

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKey(event)
                // Swallow the keystroke so it does not also reach the
                // control behind the recorder.
                return nil
            }
        }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { event in
                guard let contentView = event.window?.contentView else {
                    stopRecording()
                    return event
                }
                // AppKit window coordinates are bottom-left based; SwiftUI's
                // `.global` space is top-left based.
                let point = contentView.convert(event.locationInWindow, from: nil)
                let swiftUIPoint = CGPoint(x: point.x, y: contentView.bounds.height - point.y)
                if !frameInPane.contains(swiftUIPoint) {
                    stopRecording()
                }
                return event
            }
        }
    }

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

    private func handleKey(_ event: NSEvent) {
        switch ShortcutRecorderKey.meaning(of: event.namedKey) {
        case .cancel:
            stopRecording()
        case .restoreDefault:
            // The hotkey's default is none.
            quickTerminal.hotKey = nil
            rejection = nil
            stopRecording()
        case .record:
            guard let captured = StoredShortcut.capture(from: event) else {
                stopRecording()
                return
            }
            // Without a hotkey center (previews) there is nothing to
            // register, so no system shortcut can collide with it.
            let result = quickTerminal.validateHotKey(captured, keyboard: keyboard) { shortcut in
                hotKeyCenter?.isTakenBySystem(shortcut) ?? false
            }
            guard result == .ok else {
                // Stay armed so the user can try another combination.
                rejection = result
                return
            }
            quickTerminal.hotKey = captured
            rejection = nil
            stopRecording()
        }
    }
}
