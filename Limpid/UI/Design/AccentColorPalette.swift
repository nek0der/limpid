// AccentColorPalette.swift
// Limpid — maps each `AccentColor` case to the SwiftUI `Color` painted
// as the toolbar accent. Lives in the UI layer (not next to the
// `AccentColor` enum in Core) so the Color values can carry
// dark/light-aware variants if we ever need them — the enum itself
// stays a pure data definition.
//
// Tone targets: each named case matches the macOS Tahoe System Accent
// hue so the choice feels familiar across the OS. The colors route
// through SwiftUI's built-in semantic accents, which already track
// light / dark mode and the Increase Contrast accessibility flag.

import SwiftUI

extension AccentColor {
    /// Human-facing label shown in the Appearance picker.
    var displayName: LocalizedStringKey {
        switch self {
        case .default: "Default"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        }
    }

    /// SwiftUI `Color` for the accent point. `.default` resolves to
    /// `LimpidColor.defaultAccent` (= the macOS System Accent the user
    /// has set in System Settings) at the call site — encoded here as
    /// `nil` so callers can short-circuit to that dynamic color
    /// instead of a fixed tint.
    var color: Color? {
        switch self {
        case .default: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        }
    }
}
