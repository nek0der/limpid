// AccentRuleTests.swift
// Limpid — the rules that keep accent-colored parts legible: the contrast ratio, the primary button, accent icons, and selection edges.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

struct AccentRuleTests {
    private typealias Tokens = SupervisionTokens

    @Test func theContrastRatio_matchesWCAG() {
        #expect(ContrastRatio.between(SRGB(0xFFFFFF), SRGB(0x000000)) == 21)
        #expect(ContrastRatio.between(SRGB(0x777777), SRGB(0x777777)) == 1)
        // The figure we give for muted text on the window.
        #expect(abs(ContrastRatio.between(SRGB(0x5F656E), SRGB(0xFFFFFF)) - 5.88) < 0.01)
    }

    @Test(arguments: AccentColor.allCases)
    @MainActor
    func thePrimaryButtonsLabel_readsOnEveryAccent(_ accent: AccentColor) throws {
        for resolved in try accent.resolvedInBothAppearances() {
            let style = PrimaryButtonRule.style(onAccent: resolved.color)
            let ratio = ContrastRatio.between(style.fill, style.label)
            #expect(ratio >= ContrastRatio.text, "\(accent) in \(resolved.appearance.rawValue): \(ratio)")
            // A deep accent keeps the white label macOS buttons use.
            if ContrastRatio.between(resolved.color, PrimaryButtonRule.lightLabel) >= ContrastRatio.icon {
                #expect(style.label == PrimaryButtonRule.lightLabel, "\(accent) in \(resolved.appearance.rawValue)")
            }
        }
    }

    /// A focus ring or an accent check is 3:1 off every surface it is
    /// drawn on, a selected row and the popover's material included, not
    /// the window alone.
    @Test(arguments: AccentColor.allCases)
    @MainActor
    func anAccentIcon_showsOnEverySurfaceForEveryAccent(_ accent: AccentColor) throws {
        for resolved in try accent.resolvedInBothAppearances() {
            let isDark = resolved.isDark
            let name = resolved.appearance.rawValue
            let grounds = AccentIconRule.grounds(isDark: isDark)
            let icon = AccentIconRule.color(resolved.color, on: grounds)
            for ground in grounds + [Tokens.selection.value(isDark: isDark), Tokens.window.value(isDark: isDark)] {
                let ratio = ContrastRatio.between(icon, ground)
                #expect(ratio >= ContrastRatio.icon, "\(accent) in \(name) on \(ground): \(ratio)")
            }
            // What the window draws is the same rule.
            let appearance = try #require(NSAppearance(named: resolved.appearance))
            let drawn = try #require(SRGB(NSColor(Tokens.accentIcon(accent)), in: appearance))
            #expect(abs(drawn.luminance - icon.luminance) < 0.002, "\(accent) in \(name)")
        }
    }

    /// The yellow that a ring corrected against white alone left at 2.46:1
    /// on a selected row.
    @Test func aYellowRing_standsOffASelectedRow() {
        let grounds = AccentIconRule.grounds(isDark: false)
        let ring = AccentIconRule.color(SRGB(0xFFCC00), on: grounds)
        let ratio = ContrastRatio.between(ring, Tokens.selection.value(isDark: false))
        #expect(ratio >= ContrastRatio.icon, "\(ratio)")
        // A color that already stands off every ground is left as it is.
        let deep = SRGB(0x1F3FA0)
        #expect(AccentIconRule.color(deep, on: grounds) == deep)
    }

    /// A closed source's badge and glyph in the history: the badge's white
    /// letters are a mark on its gray, and the gray is a mark on the
    /// history's grounds, the opaque popover and the material, each held to
    /// the 3:1 contrast a mark needs.
    @Test(arguments: [false, true])
    func aClosedSourcesMark_reachesAMarksRatio(isDark: Bool) {
        let mark = Tokens.closedMark.value(isDark: isDark)
        let mode = isDark ? "dark" : "light"
        let letters = ContrastRatio.between(Tokens.badgeForeground.value(isDark: isDark), mark)
        #expect(letters >= ContrastRatio.icon, "letters in \(mode): \(letters)")
        for ground in [Tokens.popover.value(isDark: isDark), Tokens.popoverMaterial.value(isDark: isDark)] {
            let ratio = ContrastRatio.between(mark, ground)
            #expect(ratio >= ContrastRatio.icon, "mark on \(ground) in \(mode): \(ratio)")
        }
    }

    /// The segmented picker's pill is the primary button's fill on the
    /// `hover` track; its edge marks the chosen segment at 3:1.
    @Test(arguments: AccentColor.allCases)
    @MainActor
    func aSegmentedPillsEdge_standsOffItsTrackForEveryAccent(_ accent: AccentColor) throws {
        for resolved in try accent.resolvedInBothAppearances() {
            let track = Tokens.hover.value(isDark: resolved.isDark)
            let edge = Tokens.segmentedPillEdge(onAccent: resolved.color, isDark: resolved.isDark)
            let ratio = ContrastRatio.between(edge, track)
            #expect(ratio >= ContrastRatio.icon, "\(accent) in \(resolved.appearance.rawValue): \(ratio)")
        }
    }

    @Test func aSelectionEdge_keepsAFillThatAlreadyStandsOff_andMovesAwayFromTheTrackOtherwise() {
        let deep = SRGB(0x3B4FC4)
        #expect(SelectionEdgeRule.color(deep, on: SRGB(0xECEEF2)) == deep)
        // A light fill on a light track darkens; on a dark track, a dark
        // fill lightens.
        let light = SelectionEdgeRule.color(SRGB(0xFFCC00), on: SRGB(0xECEEF2))
        #expect(light.luminance < SRGB(0xFFCC00).luminance)
        #expect(ContrastRatio.between(light, SRGB(0xECEEF2)) >= ContrastRatio.icon)
        let dark = SelectionEdgeRule.color(SRGB(0x30333A), on: SRGB(0x292B30))
        #expect(dark.luminance > SRGB(0x30333A).luminance)
        #expect(ContrastRatio.between(dark, SRGB(0x292B30)) >= ContrastRatio.icon)
    }

    /// A hovered segment shows on the segmented picker's track.
    @Test(arguments: [false, true])
    func aHoveredSegment_standsOffTheTrack(isDark: Bool) {
        let ratio = ContrastRatio.between(Tokens.segmentHover.value(isDark: isDark), Tokens.hover.value(isDark: isDark))
        #expect(ratio >= 1.3, "\(ratio)")
    }

    @Test func thePrimaryButton_keepsTheAccentWhenItsLabelReads() {
        // Dark enough for white: unchanged.
        let deep = SRGB(0x2C6EE0)
        #expect(PrimaryButtonRule.style(onAccent: deep).fill == deep)
        #expect(PrimaryButtonRule.style(onAccent: deep).label == PrimaryButtonRule.lightLabel)

        // Light (yellow): the dark label, the accent unchanged.
        let light = SRGB(0xFFCC00)
        #expect(PrimaryButtonRule.style(onAccent: light).fill == light)
        #expect(PrimaryButtonRule.style(onAccent: light).label == PrimaryButtonRule.darkLabel)
    }

    @Test func aDeepAccent_isDarkenedForWhiteRatherThanGivenTheDarkLabel() {
        // macOS 26's light Blue: white 3.5:1, the dark label 4.7:1. It keeps
        // white, as a nearly identical default blue does.
        let blue = SRGB(0x0088FF)
        let style = PrimaryButtonRule.style(onAccent: blue)
        #expect(style.label == PrimaryButtonRule.lightLabel)
        #expect(ContrastRatio.between(style.fill, style.label) >= ContrastRatio.text)
    }

    @Test func aMidToneAccent_isDarkenedUntilWhiteReads() {
        // Neither label reaches 4.5:1 on this tone.
        let mid = SRGB(0x7A7A7A)
        #expect(ContrastRatio.between(mid, PrimaryButtonRule.lightLabel) < ContrastRatio.text)
        #expect(ContrastRatio.between(mid, PrimaryButtonRule.darkLabel) < ContrastRatio.text)

        let style = PrimaryButtonRule.style(onAccent: mid)
        #expect(style.label == PrimaryButtonRule.lightLabel)
        #expect(style.fill != mid)
        #expect(ContrastRatio.between(style.fill, style.label) >= ContrastRatio.text)
    }
}
