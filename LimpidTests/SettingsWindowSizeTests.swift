// SettingsWindowSizeTests.swift
// Limpid — the settings window keeps one size: a tall pane scrolls inside it, and a restored frame is brought to the fixed width.

import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Limpid

/// The window follows its content's ideal size
/// (`.windowResizability(.contentSize)`), so the content's ideal height is
/// what a hosting view fits: with the frame, every pane fits the window's
/// one height, however many rows it has.
@MainActor
struct SettingsWindowHeightTests {
    @Test func aPaneWithManyRows_fitsTheWindowsHeight_notItsRows() throws {
        try withTempDir { directory in
            let store = SettingsStore(directory: directory, writesFiles: false)
            let pane = KeyboardPane()
                .environment(store)
                .environment(ReduceTransparencyResolver())
                .environment(\.locale, Locale(identifier: "en"))
            // The pane's own rows run past the window's height; without
            // the frame the window would take their height.
            let rows = NSHostingView(rootView: pane).fittingSize
            #expect(rows.height > SettingsScene.windowHeight)

            let framed = NSHostingView(rootView: pane.settingsWindowFrame()).fittingSize
            #expect(framed.width == SettingsScene.windowWidth)
            #expect(framed.height == SettingsScene.windowHeight)
        }
    }
}

/// A restored frame is brought to the fixed width without moving its
/// top-left corner.
struct SettingsWindowWidthTests {
    @Test func frame_widerThanTheFixedWidth_narrowsAndKeepsTheTopLeftCorner() throws {
        let saved = CGRect(x: 120, y: 200, width: 1310, height: 640)
        let fitted = try #require(SettingsWindowWidth.frame(saved, width: 820))
        #expect(fitted.width == 820)
        #expect(fitted.minX == saved.minX)
        #expect(fitted.maxY == saved.maxY)
        #expect(fitted.height == saved.height)
    }

    @Test func frame_narrowerThanTheFixedWidth_widensToIt() throws {
        let saved = CGRect(x: 40, y: 60, width: 720, height: 480)
        let fitted = try #require(SettingsWindowWidth.frame(saved, width: 820))
        #expect(fitted == CGRect(x: 40, y: 60, width: 820, height: 480))
    }

    @Test func frame_atTheFixedWidth_isLeftAlone() {
        #expect(SettingsWindowWidth.frame(CGRect(x: 0, y: 0, width: 820, height: 900), width: 820) == nil)
    }
}
