// TitleBarHistoryButtons.swift
// Limpid — the title bar's back and forward buttons before the palette field.

import SwiftUI

/// Back and forward through this window's history, before the
/// palette field as a browser sets them before its address field. They
/// act on the window they are in, not on the key window, and each is off
/// while its side of the history is empty (`TitleBarHistoryModel`). Glyph
/// buttons in the window's shared style, with the menu's glyphs, so the
/// pair reads as the menu items it stands for.
struct TitleBarHistoryButtons: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let model = TitleBarHistoryModel(session: session, window: window.id)
        HStack(spacing: LimpidLayout.Supervision.titleBarHistoryButtonSpacing) {
            button(.goBack, name: "Go Back", isEnabled: model.canGoBack) {
                SupervisionWindowActions.goBack(in: window, session: session)
            }
            button(.goForward, name: "Go Forward", isEnabled: model.canGoForward) {
                SupervisionWindowActions.goForward(in: window, session: session)
            }
        }
        .fixedSize()
    }

    private func button(
        _ action: LimpidShortcutAction,
        name: LocalizedStringResource,
        isEnabled: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: action.iconName)
                .font(.supervision(.icon, weight: .medium))
                // The style pads the glyph on each side; the frame takes the
                // rest, so the hover fill is the square.
                .frame(
                    width: LimpidLayout.Supervision.titleBarHistoryButtonSize
                        - 2 * LimpidLayout.Supervision.iconButtonHorizontalPadding,
                    height: LimpidLayout.Supervision.titleBarHistoryButtonSize
                )
        }
        .buttonStyle(.supervisionIcon)
        .disabled(!isEnabled)
        .iconButtonHelp(name, shortcut: settings.settings.keyboard.shortcut(for: action)?.displayString)
    }
}
