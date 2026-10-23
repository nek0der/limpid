// SavingSuspendedAlert.swift
// Limpid — the alert at launch that settings are not being saved.

import SwiftUI

/// Tells, once at launch and in one window (`AppState.savingNoticeWindowID`),
/// that this launch cannot save the settings (`SavingSuspendedNotice.atLaunch`).
/// The same notice stays at the top of Settings → General, which Open
/// Settings goes to.
private struct SavingSuspendedAlertModifier: ViewModifier {
    let state: AppState
    /// Whether this window tells it: one window, not every one.
    let isShown: Bool

    private var notice: SavingSuspendedNotice? {
        SavingSuspendedNotice.atLaunch(
            settings: state.launchSavingSuspension,
            settingsFile: state.settingsStore.settingsFileURL,
            locale: state.settingsStore.appLocale
        )
    }

    func body(content: Content) -> some View {
        let locale = state.settingsStore.appLocale
        content.alert(
            Text(verbatim: SavingSuspendedText.launchTitle(locale: locale)),
            isPresented: Binding(
                get: { isShown && notice != nil },
                set: {
                    // Only this window's own dismissal: one the alert left
                    // for another window is not an answer.
                    if !$0, isShown {
                        state.dismissSavingNotice()
                    }
                }
            ),
            presenting: notice
        ) { _ in
            Button(SavingSuspendedText.openSettings(locale: locale)) {
                state.dismissSavingNotice()
                SettingsSection.openGeneral()
            }
            Button("OK", role: .cancel) {
                state.dismissSavingNotice()
            }
        } message: { notice in
            Text(verbatim: notice.sentences.joined(separator: "\n\n"))
        }
    }
}

extension View {
    /// The alert that settings are not being saved (`SavingSuspendedAlertModifier`).
    func savingSuspendedAlert(state: AppState, isShown: Bool) -> some View {
        modifier(SavingSuspendedAlertModifier(state: state, isShown: isShown))
    }
}
