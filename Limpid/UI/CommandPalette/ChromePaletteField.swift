// ChromePaletteField.swift
// Limpid — inline command palette trigger embedded in the L3 chrome.
// Reports its frame to WindowSession.paletteFieldFrame so the
// dropdown can be positioned at ContentView level.

import SwiftUI

struct ChromePaletteField: View {
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(\.frecencyStore) private var frecencyStore

    private var isActive: Bool {
        session.commandPaletteState != nil
    }

    var body: some View {
        pill
            .onGeometryChange(for: CGRect.self) { geo in
                geo.frame(in: .global)
            } action: { frame in
                session.paletteFieldFrame = frame
            }
    }

    @ViewBuilder
    private var pill: some View {
        if isActive, let state = session.commandPaletteState {
            ActivePill(state: state)
        } else {
            InactivePill(onTap: openPalette)
        }
    }

    private func openPalette() {
        guard let frecencyStore else { return }
        SessionActions.openCommandPalette(session, settings: settings, frecencyStore: frecencyStore)
    }
}

// MARK: - Inactive pill

private struct InactivePill: View {
    let onTap: () -> Void
    @Environment(SettingsStore.self) private var settings
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("Command Palette")
                    .font(LimpidFont.bodySecondary)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(shortcutHint)
                    .font(LimpidFont.caption)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 10)
            .frame(height: LimpidLayout.chromeContentHeight)
            .frame(maxWidth: 280)
            .background(
                isHovering ? LimpidColor.rowHoverFill : Color.primary.opacity(0.03),
                in: Capsule()
            )
            .overlay(Capsule().stroke(LimpidColor.chromeHairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var shortcutHint: String {
        settings.settings.keyboard.shortcut(for: .commandPalette)?.displayString ?? ""
    }
}

// MARK: - Active pill (text field)

private struct ActivePill: View {
    @Bindable var state: CommandPaletteState
    @Environment(WindowSession.self) private var session
    @Environment(\.frecencyStore) private var frecencyStore
    @FocusState private var fieldFocused: Bool
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Type a command or search...", text: $state.query)
                .textFieldStyle(.plain)
                .font(LimpidFont.bodySecondary)
                .focused($fieldFocused)
                .onChange(of: state.query) { _, newValue in
                    scheduleFilter(query: newValue)
                }
                .onSubmit { executeSelected() }
                .onExitCommand { SessionActions.closeCommandPalette(session) }
                .onKeyPress(.upArrow) {
                    state.moveSelection(up: true)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    state.moveSelection(up: false)
                    return .handled
                }
        }
        .padding(.horizontal, 10)
        .frame(height: LimpidLayout.chromeContentHeight)
        .frame(maxWidth: 280)
        .background(LimpidColor.rowActiveFill, in: Capsule())
        .overlay(Capsule().stroke(LimpidColor.rowActiveBorder, lineWidth: 0.5))
        .onAppear { grabFocus() }
        .onDisappear { debounceTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .limpidCommandPaletteFocus)) { _ in
            grabFocus()
        }
    }

    /// Two-tick delay: the first tick lets SwiftUI mount the TextField;
    /// the second lets the responder chain settle after the terminal
    /// surface relinquishes firstResponder.
    private func grabFocus() {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                fieldFocused = true
            }
        }
    }

    private func scheduleFilter(query: String) {
        debounceTask?.cancel()
        let capturedState = state
        let store = frecencyStore
        debounceTask = Task { @MainActor in
            capturedState.applyFilter(query: query, frecencyStore: store)
        }
    }

    private func executeSelected() {
        guard state.selectedIndex >= 0,
              state.selectedIndex < state.results.count
        else { return }
        let selected = state.results[state.selectedIndex].item
        guard selected.isEnabled else { return }
        debounceTask?.cancel()
        NotificationCenter.default.post(
            name: .limpidCommandPaletteExecute,
            object: selected.action
        )
    }
}
