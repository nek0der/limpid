// RestoreStripRowTests.swift
// Weir — the restore strip's row takes a narrower fit in a narrow pane rather than cut its buttons off.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@Suite("Restore strip row")
@MainActor
struct RestoreStripRowTests {
    private typealias Layout = WeirLayout.Supervision

    /// One of two panes side by side in the review's narrowest column, as
    /// a split lays them out (about 197pt): narrower than one of two panes
    /// split left and right in a 730pt window, where the strip's one fixed
    /// layout cut "Restore Code" and "Cancel" off. The decision bar keeps
    /// its buttons down to the same width (`DecisionBarRowFitTests`).
    private nonisolated static let halfOfTheNarrowestReview: CGFloat = 196

    /// Each fit asks for no more than the one before it, and the strip
    /// keeps its buttons ("Restore Code" and "Cancel", or "Close"), in
    /// `minimal`, down to `halfOfTheNarrowestReview`. Widths are with the
    /// foot bar's insets.
    @Test(arguments: ["en", "ja"])
    func fits_narrowInTurn_andKeepTheirButtons(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let insets = Layout.footBarLeadingInset + Layout.footBarTrailingInset
            for (strip, confirmation) in Self.strips(locale: Locale(identifier: language)) {
                let widths = RestoreStripRow.Fit.allCases.map { fit in
                    let row = Self.row(strip, confirmation, fits: [fit]).fixedSize(horizontal: true, vertical: false)
                    return Self.size(of: row, proposing: nil, language: language, settings: settings).width + insets
                }
                for (wider, narrower) in zip(widths, widths.dropFirst()) {
                    #expect(narrower < wider, "\(language) \(strip.phase): \(widths)")
                }
                #expect(widths[1] <= Self.halfOfTheNarrowestReview, "\(language) \(strip.phase): \(widths)")
            }
        }
    }

    /// From a pane as narrow as a split allows to the session's column in
    /// a 1280×800 window, the row asks for no more than the room inside
    /// the bar's insets, rather than push its buttons past the pane's edge.
    @Test(arguments: ["en", "ja"], [
        CGFloat(TerminalSettings.minPaneSizeRange.lowerBound), halfOfTheNarrowestReview, 280, 400, 580
    ])
    func row_isNoWiderThanThePane(language: String, width: CGFloat) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let room = width - Layout.footBarLeadingInset - Layout.footBarTrailingInset
            for (strip, confirmation) in Self.strips(locale: Locale(identifier: language)) {
                let size = Self.size(of: Self.row(strip, confirmation), proposing: room, language: language, settings: settings)
                #expect(size.width <= room, "\(language) at \(width): \(strip.phase)")
            }
        }
    }

    /// "Restore", the short form, is the strip's own word in both
    /// languages, and shorter than the whole.
    @Test(arguments: ["en", "ja"])
    func theShortRestore_isShorterThanTheWhole(language: String) {
        let locale = Locale(identifier: language)
        let short = RestoreText.restoreCodeShort(locale: locale)
        #expect(!short.isEmpty)
        #expect(short.count < RestoreText.restoreCode(locale: locale).count)
    }

    /// The strip asking, running, and ended short of the whole restore,
    /// with a question as long as a run of turns makes it.
    private static func strips(locale: Locale) -> [(RestoreStrip, RestoreConfirmation)] {
        let confirmation = RestoreConfirmation(
            text: RestoreText.confirmation(first: 5, last: 17, added: 12345, removed: 678, locale: locale),
            note: RestoreText.confirmationNote(isShared: true, locale: locale),
            blockedReason: nil,
            added: 12345,
            removed: 678
        )
        let turn = TurnID("T5")
        return [
            (RestoreStrip(turnID: turn), confirmation),
            (RestoreStrip(turnID: turn, phase: .running), confirmation),
            (RestoreStrip(turnID: turn, phase: .ended("The restore wrote nothing: the worktree changed while it ran.")), confirmation)
        ]
    }

    private static func row(
        _ strip: RestoreStrip,
        _ confirmation: RestoreConfirmation,
        fits: [RestoreStripRow.Fit] = RestoreStripRow.Fit.allCases
    ) -> some View {
        RestoreStripRow(strip: strip, confirmation: confirmation, isFocused: false, fits: fits, onRestore: {}, onClose: {})
    }

    private static func size(of view: some View, proposing width: CGFloat?, language: String, settings: SettingsStore) -> CGSize {
        NSHostingController(rootView: view
            .environment(settings)
            .environment(\.locale, Locale(identifier: language)))
            .sizeThatFits(in: CGSize(width: width ?? 4000, height: Layout.footBarHeight))
    }
}
