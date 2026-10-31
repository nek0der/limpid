// ProjectMarkRuleTests.swift
// Weir — a project mark's white letters read on its fill, for every palette color and accent, and keep the color's hue.

import AppKit
import SwiftUI
import Testing
@testable import Weir

struct ProjectMarkRuleTests {
    private typealias Tokens = SupervisionTokens

    @Test(arguments: WeirColor.projectPalette.indices)
    @MainActor
    func aProjectMarksWhiteLetters_readOnEveryPaletteColor(_ index: Int) throws {
        let fill = NSColor(Tokens.projectMarkFill(paletteIndex: index))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let resolved = try #require(SRGB(fill, in: appearance))
            let ratio = ContrastRatio.between(resolved, ProjectMarkRule.label)
            #expect(ratio >= ContrastRatio.text, "palette \(index) in \(name.rawValue): \(ratio)")
        }
    }

    @Test(arguments: AccentColor.allCases)
    @MainActor
    func aProjectMarksWhiteLetters_readOnEveryAccent(_ accent: AccentColor) throws {
        // A project with no palette color takes the accent, which the
        // system setting picks; each of them is darkened the same way.
        for resolved in try accent.resolvedInBothAppearances() {
            let fill = ProjectMarkRule.fill(resolved.color, paletteIndex: nil)
            let ratio = ContrastRatio.between(fill, ProjectMarkRule.label)
            #expect(ratio >= ContrastRatio.text, "\(accent) in \(resolved.appearance.rawValue): \(ratio)")
        }
    }

    @Test func aProjectMarkFill_isDarkenedOnlyAsFarAsWhiteNeeds() {
        // Indigo already reads under white; coral is darkened.
        #expect(ProjectMarkRule.fill(SRGB(0x3B4FC4), paletteIndex: 0) == SRGB(0x3B4FC4))
        let coral = ProjectMarkRule.fill(SRGB(0xEA584F), paletteIndex: 2)
        #expect(coral != SRGB(0xEA584F))
        #expect(ContrastRatio.between(coral, ProjectMarkRule.label) >= ContrastRatio.text)
    }

    /// Amber, mint, and saffron take a hand-picked fill that keeps their
    /// hue, within a few degrees, rather than the brown darkening gives.
    @Test(arguments: ProjectMarkRule.keptHueFills.keys.sorted())
    @MainActor
    func aKeptHueFill_keepsItsPaletteColorsHue(_ index: Int) throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let palette = try #require(SRGB(NSColor(WeirColor.projectPalette[index]), in: appearance))
        let kept = ProjectMarkRule.fill(palette, paletteIndex: index)
        let difference = abs(hue(of: kept) - hue(of: palette))
        #expect(min(difference, 360 - difference) <= 5, "palette \(index)")
    }

    private func hue(of color: SRGB) -> Double {
        let ns = color.nsColor
        return Double(ns.hueComponent) * 360
    }
}
