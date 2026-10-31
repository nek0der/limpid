// ToolbarPaletteField.swift
// Weir — inline command palette trigger in the window's title bar.
//
// Reports its frame to its window's `ProjectWindowState.paletteFieldFrame` so
// the dropdown can be positioned at WindowChromeHost level.

import SwiftUI

struct ToolbarPaletteField: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(SettingsStore.self) private var settings
    @Environment(AttentionState.self) private var attention
    @Environment(\.frecencyStore) private var frecencyStore
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.restoreHandler) private var restoreHandler

    /// The palette open in this window. One open in another window leaves
    /// this field idle, so the two fields never edit the same query.
    private var paletteState: CommandPaletteState? {
        session.commandPaletteState.flatMap { $0.windowID == window.id ? $0 : nil }
    }

    var body: some View {
        pill
            .onGeometryChange(for: CGRect.self) { geo in
                geo.frame(in: .global)
            } action: { frame in
                window.paletteFieldFrame = frame
            }
    }

    @ViewBuilder
    private var pill: some View {
        if let state = paletteState {
            ActivePill(state: state)
        } else {
            InactivePill(onTap: openPalette)
        }
    }

    private func openPalette() {
        guard let frecencyStore else { return }
        CommandPaletteActions.openCommandPalette(
            session,
            in: window.id,
            settings: settings,
            frecencyStore: frecencyStore,
            attention: attention,
            registry: registry,
            supervision: SupervisionPaletteFacts(
                window: window,
                session: session,
                restoreTurnNumber: restoreHandler?.paletteTurnNumber()
            )
        )
    }
}

// MARK: - Inactive pill

private struct InactivePill: View {
    let onTap: () -> Void
    @Environment(SettingsStore.self) private var settings
    @Environment(\.locale) private var locale
    @State private var isHovering = false

    /// A tooltip naming both things the field opens, and to VoiceOver the
    /// palette's name with its key, since the placeholder it shows is not a
    /// name.
    var body: some View {
        Button(action: onTap) {
            field
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text(verbatim: help))
        .accessibilityLabel(Text("Command Palette"))
        .accessibilityValue(Text(verbatim: shortcutHint))
    }

    /// The title bar's field: a field on the surfaces'
    /// color, edged in `line`, its placeholder and magnifier in the muted
    /// token, which reads at 4.5:1 on the window's color and on `hover`
    /// while the background opacity is 100%,
    /// and the palette's keys in a cap. The title bar sets its width.
    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.paletteFieldCornerRadius, style: .continuous)
        return HStack(spacing: WeirLayout.Supervision.spaceSnug) {
            Image(systemName: "magnifyingglass")
                .font(.supervision(WeirLayout.Supervision.paletteFieldSymbolSize))
                .foregroundStyle(SupervisionTokens.muted.color)
            Text("Type a command or search…")
                .font(.supervision(.body))
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !shortcutHint.isEmpty {
                // At rest the field is filled in the cap's own window color,
                // so the cap draws only its edges (`isFaceFilled`); under the
                // pointer the field turns `hover` and the cap fills its face
                // again, so it still reads as a key.
                SupervisionKeycap(keys: shortcutHint, isFaceFilled: isHovering)
            }
        }
        .padding(.horizontal, WeirLayout.Supervision.spaceS)
        .frame(height: WeirLayout.titleBarControlHeight)
        // As see-through as the title bar's ground (`SurfaceGround`), so
        // with the background opacity under 100% it is not an opaque box.
        .background(SurfaceGround {
            shape.fill(isHovering ? SupervisionTokens.hover.color : SupervisionTokens.window.color)
        })
        .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
        .contentShape(shape)
    }

    private var shortcutHint: String {
        settings.settings.keyboard.shortcut(for: .commandPalette)?.displayString ?? ""
    }

    /// The two things the field opens, each with its key: the palette, and
    /// Quick Open, which has no other way in from the title bar.
    private var help: String {
        let keyboard = settings.settings.keyboard
        return [
            ShortcutHelpText.make(
                name: "Command Palette",
                shortcut: keyboard.shortcut(for: .commandPalette)?.displayString,
                locale: locale
            ),
            ShortcutHelpText.make(name: "Quick Open", shortcut: keyboard.shortcut(for: .quickOpen)?.displayString, locale: locale)
        ].joined(separator: "\n")
    }
}

// MARK: - Active pill (text field)

private struct ActivePill: View {
    @Bindable var state: CommandPaletteState
    @Environment(WorkspaceSession.self) private var session
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(\.frecencyStore) private var frecencyStore
    @FocusState private var fieldFocused: Bool
    @State private var debounceTask: Task<Void, Never>?

    /// The field while typing: the idle field's shape, the text in the text
    /// color, and the accent's 2pt ring just inside its edge for where the
    /// keys go.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.paletteFieldCornerRadius, style: .continuous)
        return HStack(spacing: WeirLayout.Supervision.spaceSnug) {
            Image(systemName: "magnifyingglass")
                .font(.supervision(WeirLayout.Supervision.paletteFieldSymbolSize))
                .foregroundStyle(SupervisionTokens.muted.color)
            field
                .font(.supervision(.body))
                .foregroundStyle(SupervisionTokens.text.color)
        }
        .padding(.horizontal, WeirLayout.Supervision.spaceS)
        .frame(height: WeirLayout.titleBarControlHeight)
        .background(SurfaceGround { shape.fill(SupervisionTokens.window.color) })
        // The field shows only while it is typed in, so its ring is always
        // drawn; on the edge, where the idle field's own edge was.
        .supervisionFocusRing(
            isFocused: true,
            cornerRadius: WeirLayout.Supervision.paletteFieldCornerRadius,
            placement: .onEdge
        )
        .modifier(FieldLifecycle(onAppear: grabFocus, onDisappear: { debounceTask?.cancel() }))
    }

    /// The placeholder takes the muted token, which reads at 4.5:1 on its
    /// field, as the window's other plain fields do.
    private var field: some View {
        TextField(
            text: $state.query,
            prompt: Text(state.placeholder).foregroundStyle(SupervisionTokens.muted.color)
        ) {
            Text(state.placeholder)
        }
        .textFieldStyle(.plain)
        .focused($fieldFocused)
        .onChange(of: state.query) { _, newValue in
            scheduleFilter(query: newValue)
        }
        .onSubmit { executeSelected() }
        // ⌘Return opens another project's row in a new window; the
        // window reads it only for those rows.
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.chord == .command else { return .ignored }
            executeSelected(opensInNewWindow: true)
            return .handled
        }
        .onExitCommand { CommandPaletteActions.closeCommandPalette(session) }
        .onKeyPress(.upArrow) {
            state.moveSelection(up: true)
            return .handled
        }
        .onKeyPress(.downArrow) {
            state.moveSelection(up: false)
            return .handled
        }
    }

    /// Takes the keyboard once the terminal has let go
    /// (`KeyboardHandoff`). The initialQuery is applied a turn after focus
    /// so the cursor lands at the end, not selecting all.
    private func grabFocus() {
        KeyboardHandoff.afterResponderSettles {
            fieldFocused = true
            if let initial = state.initialQuery {
                state.initialQuery = nil
                DispatchQueue.main.async {
                    state.query = initial
                }
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

    private func executeSelected(opensInNewWindow: Bool = false) {
        guard state.selectedIndex >= 0,
              state.selectedIndex < state.results.count
        else { return }
        let selected = state.results[state.selectedIndex].item
        guard selected.isEnabled else { return }

        // insertPrefix swaps the query instead of dismissing.
        if case let .insertPrefix(mode) = selected.action {
            state.query = String(mode.character)
            return
        }

        debounceTask?.cancel()
        CommandPaletteActions.postExecution(of: selected.action, from: state, opensInNewWindow: opensInNewWindow, commands: windowRegistry)
    }
}

/// What the typing field does as it comes and goes: it takes the keyboard
/// on arrival and whenever the palette is asked to focus, and drops its
/// pending filter as it leaves.
private struct FieldLifecycle: ViewModifier {
    let onAppear: () -> Void
    let onDisappear: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
            .onReceive(NotificationCenter.default.publisher(for: .weirCommandPaletteFocus)) { _ in
                onAppear()
            }
    }
}
