// AccentColorPicker.swift
// Weir — inline accent picker used by the Appearance pane. Modeled
// on macOS Tahoe System Settings → Appearance → Accent Color: a
// horizontal row of solid swatches with a Multicolor (rainbow angular
// gradient) leading dot for the "follow the OS" choice and a ring in
// the chosen hue around the active swatch. No textual label under the
// row — the swatch hue already names itself, so the label would be
// noise.

import SwiftUI

struct AccentColorPicker: View {
    let current: AccentColor
    let onSelect: (AccentColor) -> Void

    var body: some View {
        // 2pt spacing matches the dot-to-dot gap macOS Tahoe System
        // Settings → Appearance → Accent Color uses; pushing it
        // wider makes the row read as "buttons with margins" rather
        // than "a palette".
        HStack(spacing: 2) {
            ForEach(AccentColor.allCases, id: \.self) { choice in
                swatch(choice)
            }
        }
        // One choice among several, so one stop for the keyboard: ← and →
        // move the selection, as a macOS radio group does, rather than
        // a Tab stop per swatch. VoiceOver reads the row as the "Accent" group,
        // each swatch with its name and whether it is the selected one.
        .focusable()
        .onKeyPress(.leftArrow) { step(by: -1) }
        .onKeyPress(.rightArrow) { step(by: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Accent"))
    }

    /// Selects the swatch `offset` places from the current one, held to
    /// the row's ends.
    private func step(by offset: Int) -> KeyPress.Result {
        let choices = AccentColor.allCases
        guard let index = choices.firstIndex(of: current) else { return .ignored }
        let next = min(max(index + offset, 0), choices.count - 1)
        if next != index {
            onSelect(choices[next])
        }
        return .handled
    }

    @ViewBuilder
    private func swatch(_ choice: AccentColor) -> some View {
        let isSelected = current == choice
        Button {
            onSelect(choice)
        } label: {
            ZStack {
                // Selection ring sits *outside* the dot, in the same
                // hue the dot itself paints. Same pattern macOS uses
                // — the ring reads as "this is the active pick".
                if isSelected {
                    Circle()
                        .stroke(WeirColor.accent(for: choice), lineWidth: 2.5)
                        .frame(width: 30, height: 30)
                }
                dotFill(for: choice)
                    .frame(width: 22, height: 22)
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The row takes the keyboard as one stop; a swatch is clicked.
        .focusable(false)
        .help(Text(choice.displayName))
        .accessibilityLabel(Text(choice.displayName))
        // The ring alone carries the choice on screen; this carries it to VoiceOver.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// `.default` paints the macOS Multicolor swatch — an angular
    /// rainbow that telegraphs "follow the OS-wide Accent". The
    /// other cases paint a flat solid in the matching `systemXxx`
    /// hue (SwiftUI's `.blue` / `.purple` / … route through
    /// `NSColor.systemBlue` etc., which match System Settings).
    @ViewBuilder
    private func dotFill(for choice: AccentColor) -> some View {
        if choice == .default {
            Circle()
                .fill(
                    AngularGradient(
                        colors: [.blue, .purple, .pink, .red, .orange, .yellow, .green, .blue],
                        center: .center
                    )
                )
        } else {
            Circle().fill(WeirColor.accent(for: choice))
        }
    }
}
