// SupervisionFocusRingTests.swift
// Limpid — the keyboard's ring takes the accent chosen in the settings, and stands where each placement puts it.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@Suite("Supervision focus ring")
@MainActor
struct SupervisionFocusRingTests {
    /// With purple chosen, the ring is purple made readable on the window,
    /// in both appearances: the store's accent, not the system's.
    @Test func theRing_takesTheAccentChosenInTheSettings() throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            settings.settings.appearance.accentColor = .purple
            let ring = NSColor(SupervisionFocusRing.color(in: settings))
            let purple = NSColor(SupervisionTokens.accentIcon(.purple))
            let orange = NSColor(SupervisionTokens.accentIcon(.orange))
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: name))
                let resolved = try #require(SRGB(ring, in: appearance))
                #expect(resolved == SRGB(purple, in: appearance), "\(name.rawValue)")
                #expect(resolved != SRGB(orange, in: appearance), "\(name.rawValue)")
            }
        }
    }

    /// On the edge, the ring is the edge: a row flush against its
    /// neighbors keeps it inside itself.
    @Test func onEdgeRing_staysInsideTheEdge() {
        let geometry = SupervisionFocusRing.geometry(cornerRadius: 8, placement: .onEdge)
        #expect(geometry.outset == 0)
        #expect(geometry.cornerRadius == 8)
    }

    /// On a surface that stands still, the ring is where the keyboard is
    /// and nowhere else.
    @Test func onAStillSurface_theRingFollowsTheKeyboard() {
        var hold = SupervisionFocusRing.Hold()
        #expect(!hold.isDrawn(isFocused: false, isSurfaceInTransition: false))
        hold.update(isFocused: true, isSurfaceInTransition: false)
        #expect(hold.isDrawn(isFocused: true, isSurfaceInTransition: false))
        hold.update(isFocused: false, isSurfaceInTransition: false)
        #expect(!hold.isDrawn(isFocused: false, isSurfaceInTransition: false))
    }

    /// A closing dropdown hands the keyboard back to the terminal at once;
    /// its field's ring stays and fades with the dropdown, as one part of
    /// it, rather than blinking off ahead of the rest.
    @Test func onASurfaceFadingOut_theRingStaysWhereTheKeyboardWas() {
        var hold = SupervisionFocusRing.Hold()
        hold.update(isFocused: true, isSurfaceInTransition: false)
        hold.update(isFocused: false, isSurfaceInTransition: true)
        #expect(hold.isDrawn(isFocused: false, isSurfaceInTransition: true))
    }

    /// A field that never had the keyboard gets no ring from the fade.
    @Test func onASurfaceFadingOut_noRingIsDrawnWhereTheKeyboardNeverWas() {
        var hold = SupervisionFocusRing.Hold()
        hold.update(isFocused: false, isSurfaceInTransition: false)
        hold.update(isFocused: false, isSurfaceInTransition: true)
        #expect(!hold.isDrawn(isFocused: false, isSurfaceInTransition: true))
    }

    /// The keyboard reaches a dropdown's field while the dropdown is still
    /// fading in: the ring is drawn at once, and stays once the dropdown
    /// stands still.
    @Test func onASurfaceFadingIn_theRingComesWithTheKeyboard() {
        var hold = SupervisionFocusRing.Hold()
        hold.update(isFocused: true, isSurfaceInTransition: true)
        #expect(hold.isDrawn(isFocused: true, isSurfaceInTransition: true))
        hold.update(isFocused: true, isSurfaceInTransition: false)
        #expect(hold.isDrawn(isFocused: true, isSurfaceInTransition: false))
        hold.update(isFocused: false, isSurfaceInTransition: false)
        #expect(!hold.isDrawn(isFocused: false, isSurfaceInTransition: false))
    }
}
