// KeyboardShortcutOverlay.swift
// Weir — lays the keyboard shortcuts panel over its window, dimming what is behind it, as All Projects is.

import SwiftUI

/// The keyboard shortcuts panel over its window while
/// `ProjectWindowState.keyboardShortcuts` is presented. An overlay rather
/// than a system sheet, so it comes and goes as All Projects does
/// (`ModalMotion.overlayPanel` over `.overlayScrim`) and a click outside it
/// closes it on the scrim, with no monitor of the window's clicks.
struct KeyboardShortcutOverlay: View {
    let state: AppState
    /// True while another modal (the OSC 52 clipboard confirmation) needs
    /// the window: the panel closes so that confirmation is never held back
    /// behind a reference panel.
    let yieldsToOtherModal: Bool
    @Environment(ProjectWindowState.self) private var window

    private var presentation: KeyboardShortcutPresentation {
        window.keyboardShortcuts
    }

    var body: some View {
        WindowOverlayHost(isPresented: presentation.isPresented, onDismiss: close) { proxy in
            KeyboardShortcutPanel(
                maxHeight: Self.panelHeight(forWindowHeight: proxy.size.height),
                onClose: close,
                onCustomize: {
                    SettingsSection.openKeyboard()
                    close()
                }
            )
            .environment(state.settingsStore)
            .environment(\.locale, state.settingsStore.appLocale)
            .weirAccentPropagated(
                WeirColor.accent(for: state.settingsStore.settings.appearance.accentColor)
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onWindowCommand(of: window) { command in
            guard command == .toggleKeyboardShortcuts else { return false }
            KeyboardShortcutPanelActions.toggle(window, session: state.session, registry: state.registry)
            return true
        }
        // The panel goes as another layer comes: the palette, a title bar
        // menu, the notification history, or All Projects opened by its
        // key. That layer has the keyboard, so it is not handed back.
        .onChange(of: window.isAnotherLayerOpen(than: .keyboardShortcuts, session: state.session)) { _, isOpen in
            if isOpen, presentation.isPresented {
                presentation.isPresented = false
            }
        }
        // The confirmation's sheet takes the keyboard while it is up; the
        // window's terminal has it back after.
        .onChange(of: yieldsToOtherModal) { _, needsWindow in
            if needsWindow, presentation.isPresented {
                close()
            }
        }
    }

    private func close() {
        KeyboardShortcutPanelActions.close(window, session: state.session, registry: state.registry)
    }

    /// The panel's height in a window `windowHeight` tall: the main window
    /// can shrink to 400pt, below the panel's preferred 640pt, and a panel
    /// taller than its window puts the footer out of reach. It leaves a
    /// margin above and below, down to the least height at which the list
    /// is still of use.
    static func panelHeight(forWindowHeight windowHeight: CGFloat) -> CGFloat {
        min(
            KeyboardShortcutPanel.preferredHeight,
            max(KeyboardShortcutPanel.minimumHeight, windowHeight - WeirLayout.Supervision.sheetWindowMargin)
        )
    }
}
