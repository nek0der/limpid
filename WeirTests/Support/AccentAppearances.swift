// AccentAppearances.swift
// Weir — an accent color as the light and the dark appearance resolve it, for the contrast suites.

import AppKit
import SwiftUI
import Testing
@testable import Weir

/// An accent resolved in one appearance.
struct ResolvedAccent {
    let appearance: NSAppearance.Name
    let isDark: Bool
    let color: SRGB
}

extension AccentColor {
    /// This accent as the light and then the dark appearance draw it.
    @MainActor
    func resolvedInBothAppearances() throws -> [ResolvedAccent] {
        let accentColor = NSColor(WeirColor.accent(for: self))
        return try [(NSAppearance.Name.aqua, false), (.darkAqua, true)].map { name, isDark in
            let appearance = try #require(NSAppearance(named: name))
            return try ResolvedAccent(appearance: name, isDark: isDark, color: #require(SRGB(accentColor, in: appearance)))
        }
    }
}

extension SRGB {
    /// The color's channels as 0–255 values, the precision a written-out
    /// hex has.
    var hexBytes: [Int] {
        [red, green, blue].map { Int(($0 * 255).rounded()) }
    }
}
