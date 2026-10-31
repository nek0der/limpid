// SupervisionPrimaryButtonStyle.swift
// Weir — the supervision UI's primary button: the accent fill and label that keep their contrast.

import SwiftUI

/// The one button a bar or band leads with ("Mark as Viewed").
///
/// Its own style rather than `.borderedProminent`: the native fill is the
/// raw accent, which with white text falls under 4.5:1 for the default blue
/// and for purple, and under 3:1 for the light accents.
/// `SupervisionTokens.primaryButton` darkens the fill or darkens the label
/// until the pair reads.
struct SupervisionPrimaryButtonStyle: ButtonStyle {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let colors = SupervisionTokens.primaryButton(settings.settings.appearance.accentColor)
        configuration.label
            // Medium, as the secondary button beside it: the fill alone
            // sets it apart.
            .font(.supervision(.row, weight: .medium))
            .foregroundStyle(colors.label)
            .fixedSize()
            .padding(.horizontal, WeirLayout.Supervision.spaceM)
            .frame(height: WeirLayout.Supervision.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: WeirLayout.Supervision.buttonCornerRadius, style: .continuous)
                    .fill(colors.fill.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .opacity(isEnabled ? 1 : SupervisionTokens.disabledOpacity)
            .contentShape(RoundedRectangle(cornerRadius: WeirLayout.Supervision.buttonCornerRadius, style: .continuous))
    }
}
