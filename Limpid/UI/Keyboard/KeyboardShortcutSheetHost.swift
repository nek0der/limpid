// KeyboardShortcutSheetHost.swift
// Limpid — window-level wiring for the keyboard shortcut cheat sheet:
// listens for the toggle notification, presents the sheet, and sizes
// it to the window. Kept out of `LimpidApp` so the app file stays
// under the file-length limit, mirroring `NotificationHistoryOverlay`.

import SwiftUI

extension View {
    /// Hosts the cheat sheet on this window's content. `yieldsTo` is
    /// true while another modal (the OSC 52 clipboard confirmation)
    /// needs the window: the sheet closes so that confirmation is never
    /// held back behind a reference panel.
    func keyboardShortcutSheet(state: AppState, yieldsTo yieldsToOtherModal: Bool) -> some View {
        modifier(KeyboardShortcutSheetHost(state: state, yieldsToOtherModal: yieldsToOtherModal))
    }
}

private struct KeyboardShortcutSheetHost: ViewModifier {
    let state: AppState
    let yieldsToOtherModal: Bool

    /// The window's content height, so the sheet never outgrows the
    /// window: the main window can shrink to 400pt, below the sheet's
    /// preferred 640pt, and a sheet taller than its parent puts the
    /// footer buttons out of reach.
    @State private var windowHeight: CGFloat = 0

    private var presentation: KeyboardShortcutPresentation {
        state.keyboardShortcutPresentation
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                windowHeight = height
            }
            .onReceive(NotificationCenter.default.publisher(for: .limpidToggleKeyboardShortcuts)) { note in
                guard let owner = note.object as? WindowSession, owner === state.session else { return }
                CommandPaletteActions.closeCommandPalette(state.session)
                presentation.isPresented.toggle()
            }
            .onChange(of: yieldsToOtherModal) { _, needsWindow in
                if needsWindow {
                    presentation.isPresented = false
                }
            }
            .sheet(isPresented: Binding(
                get: { presentation.isPresented },
                set: { presentation.isPresented = $0 }
            )) {
                KeyboardShortcutSheet(maxHeight: sheetMaxHeight) {
                    // Land on the Keyboard pane: the Settings scene reads the
                    // last section from this key when it opens.
                    UserDefaults.standard.set(
                        SettingsSection.keyboard.rawValue,
                        forKey: SettingsSection.lastSectionDefaultsKey
                    )
                    NotificationCenter.default.post(name: .limpidOpenSettings, object: nil)
                }
                .environment(state.settingsStore)
                .environment(\.locale, state.settingsStore.appLanguage.locale ?? .current)
                .limpidAccentPropagated(
                    LimpidColor.accent(for: state.settingsStore.settings.appearance.accentColor)
                )
            }
    }

    /// Leaves a margin above and below the sheet. Before the first
    /// geometry pass `windowHeight` is 0; the sheet then falls back to
    /// its preferred height rather than collapsing.
    private var sheetMaxHeight: CGFloat {
        guard windowHeight > 0 else { return KeyboardShortcutSheet.preferredHeight }
        return min(KeyboardShortcutSheet.preferredHeight, max(KeyboardShortcutSheet.minimumHeight, windowHeight - 48))
    }
}
