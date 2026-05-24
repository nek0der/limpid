// WindowTintColors.swift
// Limpid — maps each `WindowTint` case to the colour the L2 / L3
// column fills paint with. Lives in the UI layer (not next to the
// `WindowTint` enum in Core) so the Color values can carry
// dark/light-aware variants if we ever need them — the enum itself
// stays a pure data definition.
//
// Tone targets: each tint should read as "dark + a hint of <hue>"
// against libghostty's default ANSI palette. The base RGB is
// roughly the same lightness as `LimpidColor.l3Background` so the
// chrome's rhythm (slab vs background contrast) stays consistent
// across tints.

import SwiftUI

extension WindowTint {
    /// Human-facing label shown in the Appearance picker.
    var displayName: LocalizedStringKey {
        switch self {
        case .default: "Default"
        case .slate: "Slate"
        case .navy: "Navy"
        case .plum: "Plum"
        case .forest: "Forest"
        case .amber: "Amber"
        case .crimson: "Crimson"
        case .black: "Black"
        }
    }

    /// SwiftUI `Color` for the column fill. `.default` resolves to
    /// `LimpidColor.l3Background` (Limpid's stock grey) at the call
    /// site — encoded here as `nil` so callers can short-circuit.
    var fillColor: Color? {
        switch self {
        case .default: nil
        case .slate: Color(red: 0.18, green: 0.21, blue: 0.27)
        case .navy: Color(red: 0.09, green: 0.13, blue: 0.24)
        case .plum: Color(red: 0.19, green: 0.12, blue: 0.24)
        case .forest: Color(red: 0.10, green: 0.18, blue: 0.13)
        case .amber: Color(red: 0.22, green: 0.16, blue: 0.07)
        case .crimson: Color(red: 0.22, green: 0.10, blue: 0.12)
        case .black: Color(red: 0.05, green: 0.05, blue: 0.06)
        }
    }
}
