// SettingsRecorderPill.swift
// Limpid — the pill a shortcut recorder in Settings is drawn as, recording or not.

import SwiftUI

/// The shape every shortcut recorder in Settings takes (Keyboard's rows, the
/// Quick Terminal hotkey, and the Keyboard row that opens the Quick Terminal
/// pane), so the pills line up and read alike: a gray fill at rest, an
/// accent tint and edge while it records.
struct SettingsRecorderPill: ViewModifier {
    let isRecording: Bool

    @Environment(\.limpidAccent) private var accent

    /// How strong the fill is: the accent's while recording, the gray's at
    /// rest.
    private static let recordingFillOpacity = 0.2
    private static let restingFillOpacity = 0.12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.settingsRecorderPillCornerRadius)
        content
            .padding(.horizontal, LimpidLayout.settingsRecorderPillHorizontalPadding)
            .frame(height: LimpidLayout.settingsRecorderPillHeight)
            .background(
                shape.fill(
                    isRecording
                        ? accent.opacity(Self.recordingFillOpacity)
                        : Color.secondary.opacity(Self.restingFillOpacity)
                )
            )
            .overlay(shape.stroke(isRecording ? accent : Color.clear, lineWidth: 1))
    }
}

extension View {
    /// Draws the view as a shortcut recorder's pill (`SettingsRecorderPill`).
    func settingsRecorderPill(isRecording: Bool = false) -> some View {
        modifier(SettingsRecorderPill(isRecording: isRecording))
    }
}
