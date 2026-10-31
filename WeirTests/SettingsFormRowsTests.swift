// SettingsFormRowsTests.swift
// Weir — the shared Settings rows' rules: a typed number held to its range and step, a path revealed where it exists,
// and a caption that stays readable on the settings window.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Weir

@MainActor
struct SettingsFormRowsTests {
    /// A value row's label yields to its controls, so a long label (the
    /// Japanese "Unfocused pane opacity") wraps inside the row rather than
    /// having the form stack the label over the controls, which made a tall
    /// box with a gap above the slider (`SettingsValueRowTitle`).
    @Test @MainActor func aValueRowWithALongLabel_staysARow() throws {
        try withTempDir { directory in
            let store = SettingsStore(directory: directory, writesFiles: false)
            @MainActor func height(of title: LocalizedStringResource) -> CGFloat {
                let form = SettingsForm(title: "Probe", section: .appearance) {
                    Section {
                        SliderRow(title: title, value: .constant(0.7), range: 0.15...1.0, defaultValue: 0.7)
                    } footer: {
                        SettingsFootnote("Footer")
                    }
                }
                .environment(store)
                .environment(ReduceTransparencyResolver())
                .environment(\.locale, Locale(identifier: "ja"))
                return fittingHeight(of: form)
            }
            let short = height(of: "Opacity")
            let long = height(of: "フォーカスされていないペインの不透明度")
            // A second line of the label at most, never a stacked row.
            #expect(long - short < 24, "\(long) against \(short)")
        }
    }

    @Test func aTypedNumber_isHeldToTheRangeAndTheStep() {
        #expect(SettingsNumberRow.held(13.3, to: 6...72, step: 0.5) == 13.5)
        #expect(SettingsNumberRow.held(200, to: 6...72, step: 0.5) == 72)
        #expect(SettingsNumberRow.held(0, to: 1...90, step: 1) == 1)
    }

    @Test func aValueRow_offersRestoreDefault_onlyAwayFromItsDefault() {
        #expect(!RestoreDefaultSlot.isShown(value: 13, defaultValue: 13))
        #expect(RestoreDefaultSlot.isShown(value: 15, defaultValue: 13))
        // A slider is read as its readout: a hair from the default, which
        // the readout shows as the default, offers nothing.
        #expect(!RestoreDefaultSlot.isShown(value: 0.9204, defaultValue: 0.92, tolerance: 0.005))
        #expect(RestoreDefaultSlot.isShown(value: 0.95, defaultValue: 0.92, tolerance: 0.005))
        // A row with no default of its own offers none.
        #expect(!RestoreDefaultSlot.isShown(value: 15, defaultValue: nil))
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        #expect(RestoreDefaultSlot.label(for: "Size").resolved(in: en) == "Restore Default Size")
        #expect(RestoreDefaultSlot.label(for: "Size").resolved(in: ja) == "サイズをデフォルトに戻す")
    }

    @Test func revealingAFolderYetToBeMade_showsTheNearestThatExists() {
        let existing: Set = ["/", "/Users", "/Users/someone/repos"]
        let target = PathRow.nearestExisting(
            URL(fileURLWithPath: "/Users/someone/repos/app-<branch>"),
            exists: existing.contains
        )

        #expect(target?.path == "/Users/someone/repos")
    }

    // MARK: - The caption's contrast

    /// A settings caption (`SettingsFootnote`) on the settings window: the
    /// light behind-window glass as measured on macOS 26 beside the footers
    /// (#E8E8E8), and the opaque window background Reduce Transparency
    /// paints, in both appearances.
    @Test(arguments: [false, true])
    func aSettingsCaption_reachesFourAndAHalfToOneOnTheSettingsBackground(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let caption = SettingsFootnote.style.value(isDark: isDark)
        let opaque = try #require(SRGB(NSColor.windowBackgroundColor, in: appearance))
        var grounds = [("the opaque window background", opaque)]
        if !isDark {
            grounds.append(("the measured glass", SRGB(0xE8E8E8)))
        }
        let mode = isDark ? "dark" : "light"
        for (name, ground) in grounds {
            let ratio = ContrastRatio.between(caption, ground)
            #expect(ratio >= ContrastRatio.text, "settings caption on \(name) in \(mode): \(ratio)")
        }
    }

    /// The dark glass, measured beside the footers at about #3A3A3A, is the
    /// one settings ground the caption does not reach 4.5:1 on (4.28:1).
    /// The glass follows the wallpaper, so `SettingsFootnote` records the
    /// gap instead of tuning a color for it; this holds the caption where
    /// it is, so a darker `muted` shows up here.
    @Test func aSettingsCaption_onTheDarkGlass_staysAtItsMeasuredContrast() {
        let ratio = ContrastRatio.between(SettingsFootnote.style.value(isDark: true), SRGB(0x3A3A3A))
        #expect(ratio > 4.25, "settings caption on the dark glass: \(ratio)")
    }
}
