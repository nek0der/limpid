// MenuBarAppearanceTests.swift
// Weir — the menu bar extra's window follows the system's appearance, and its ink and surface with it.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Weir

/// The menu's window follows the system's appearance, read from the
/// global defaults: "Dark" in dark mode, nothing in light.
@MainActor
struct MenuBarAppearanceTests {
    @Test func theSystemsStyle_namesDark_orIsAbsentInLight() {
        #expect(MenuBarAppearance.isDark(interfaceStyle: "Dark"))
        #expect(MenuBarAppearance.isDark(interfaceStyle: "dark"))
        #expect(!MenuBarAppearance.isDark(interfaceStyle: nil))
        #expect(!MenuBarAppearance.isDark(interfaceStyle: "Light"))
        #expect(!MenuBarAppearance.isDark(interfaceStyle: ""))
    }

    /// Read from the defaults handed in. In-memory ones, so the test neither
    /// reads the machine's appearance nor writes a suite of its own to
    /// `~/Library/Preferences`.
    @Test func theSystemsAppearance_isReadFromTheDefaultsGiven() throws {
        let defaults = try #require(InMemoryDefaults())

        #expect(!MenuBarAppearance.isSystemDark(defaults: defaults), "light leaves the key unset")
        defaults.set("Dark", forKey: MenuBarAppearance.interfaceStyleKey)
        #expect(MenuBarAppearance.isSystemDark(defaults: defaults))
        defaults.set("Light", forKey: MenuBarAppearance.interfaceStyleKey)
        #expect(!MenuBarAppearance.isSystemDark(defaults: defaults))
    }

    /// The menu's words are the system's labels, which mix with what shows
    /// through its glass; Weir's own panels keep the tokens.
    @Test func theMenusInk_isTheSystemsLabels_andThePanelsIsTheTokens() {
        #expect(EnvironmentValues().popoverSurface.ink == .tokens)
        #expect(PopoverInk.vibrant.text == .primary)
        #expect(PopoverInk.vibrant.muted == .secondary)
        #expect(PopoverInk.tokens.text == SupervisionTokens.text.color)
        #expect(PopoverInk.tokens.muted == SupervisionTokens.muted.color)
        #expect(PopoverInk.tokens.line == SupervisionTokens.line.color)
    }

    /// One fact, the surface, decides the ground, the rows' lighting, and
    /// the ink together, so no view in the menu can read the menu's ground
    /// and still draw Weir's tokens on it.
    @Test func theMenusSurface_decidesItsGroundHighlightAndInkTogether() {
        let menu = PopoverSurface.systemMenu
        #expect(menu.ground == .material)
        #expect(menu.rowHighlight == .systemMenu)
        #expect(menu.ink == .vibrant)
        for ground in [PopoverGround.opaque, .material] {
            let panel = PopoverSurface.weir(ground)
            #expect(panel.ground == ground)
            #expect(panel.rowHighlight == .ground)
            #expect(panel.ink == .tokens)
        }
        #expect(EnvironmentValues().popoverSurface == .weir(.opaque))
    }

    /// The capacity warning's words read on the menu's glass, as the rest
    /// of the menu's do; the amber stays on its icon, and in Weir's own
    /// panels on the words too.
    @Test func theCapacityWarning_takesTheSurfacesInk() {
        #expect(PopoverInk.vibrant.warningText == .primary)
        #expect(PopoverInk.tokens.warningText == SupervisionTokens.waitingText.color)
    }

    /// On the menu's glass words in the stop color and the unread ring take
    /// the system's label; Weir's own panels keep the red and the accent.
    @Test func aStopsWordsAndTheUnreadRing_takeTheSurfacesInk() {
        #expect(PopoverInk.vibrant.stoppedText == .primary)
        #expect(PopoverInk.vibrant.unreadMark == .primary)
        #expect(PopoverInk.tokens.stoppedText == SupervisionTokens.stoppedText.color)
        #expect(PopoverInk.tokens.unreadMark == nil)
    }

    /// The menu's content draws in the system's scheme, the one its window
    /// wears, whatever the app's theme pins `NSApp.appearance` to.
    @Test func theMenusScheme_isTheSystems() {
        #expect(SupervisionMenuBarContent.colorScheme(isSystemDark: true) == .dark)
        #expect(SupervisionMenuBarContent.colorScheme(isSystemDark: false) == .light)
    }

    /// A dark menu bar over a light app theme: the tokens the menu draws
    /// its quiet words in (`muted`, the heading's and the time's) resolve
    /// to their dark values under the menu's appearance, not the app's.
    @Test @MainActor
    func theTokens_resolveAgainstTheMenusAppearance_notTheAppsPinnedOne() throws {
        let app = NSApplication.shared
        let pinned = app.appearance
        app.appearance = NSAppearance(named: .aqua)
        defer { app.appearance = pinned }

        let dark = try #require(NSAppearance(named: .darkAqua))
        for token in [SupervisionTokens.muted, SupervisionTokens.text, SupervisionTokens.faint] {
            var resolved: NSColor?
            dark.performAsCurrentDrawingAppearance {
                resolved = NSColor(token.color).usingColorSpace(.sRGB)
            }
            let color = try #require(resolved)
            let expected = token.value(isDark: true)
            #expect(abs(color.redComponent - expected.red) < 0.01)
            #expect(abs(color.greenComponent - expected.green) < 0.01)
            #expect(abs(color.blueComponent - expected.blue) < 0.01)
        }
    }
}
