// ChangesPanelCardFitTests.swift
// Limpid — a turn card's moves and the viewed line's Unmark stay inside the changes panel, down to its narrowest.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

extension SupervisionFootBarTests {

    // MARK: - A turn card's moves across the changes panel

    /// The room a turn card gives its moves in a panel `width` wide: the
    /// list's inset on both sides, and the card's under its words.
    private static func turnMovesWidth(panel width: CGFloat, hasConversation: Bool = false) -> CGFloat {
        let insets = Layout.turnActionInsets(hasConversation: hasConversation)
        return width - 2 * Layout.changesListInset - insets.leading - insets.trailing
    }

    /// At the panel's narrowest, each card's moves stay inside the card:
    /// in English the whole restore entry is wider than the room, and the
    /// card takes "Restore Code…" instead. A card with its conversation's
    /// badge has less room, and its moves that reach every conversation
    /// take their short labels where the whole ones do not fit.
    @Test(arguments: ["en", "ja"])
    func turnCardMoves_stayInsideTheCard_atThePanelsNarrowest(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let locale = Locale(identifier: language)
            let room = Self.turnMovesWidth(panel: Layout.changesPanelWidthRange.lowerBound)
            for moves in Self.turnCardMoves(locale: locale) {
                let size = Self.size(of: moves, proposing: room, language: language, settings: settings)
                #expect(size.width <= room, "\(language) at \(room)")
            }
            let badged = Self.turnMovesWidth(panel: Layout.changesPanelWidthRange.lowerBound, hasConversation: true)
            for moves in Self.turnCardMoves(locale: locale, movesOtherLines: true) {
                let size = Self.size(of: moves, proposing: badged, language: language, settings: settings)
                #expect(size.width <= badged, "\(language) across conversations at \(badged)")
            }
            // The short labels fit whole, not cut: when no label fits,
            // ViewThatFits cuts its last one to the room, which the widths
            // above would pass.
            for action in [ChangesPanelModel.RowAction.markViewedThrough, .markUnviewedFrom] {
                let short = try #require(ChangesPanelText.shortAction(action, movesOtherLines: true, locale: locale))
                let alone = TurnCardMoves(lineMove: .init(title: short) {}, restore: nil)
                let ideal = Self.size(of: alone, proposing: nil, language: language, settings: settings)
                #expect(ideal.width <= badged, "\(language): “\(short)” is \(ideal.width)pt whole, past \(badged)pt")
            }
            let whole = Self.size(of: Self.wholeRestoreEntry(locale: locale), proposing: nil, language: language, settings: settings)
            if language == "en" {
                #expect(whole.width > room, "the short form is what keeps the entry inside")
            }
        }
    }

    /// At the panel's default width the card has room for the whole entry
    /// on a line of its own, and draws it whole.
    @Test(arguments: ["en", "ja"])
    func turnCardMoves_keepTheWholeRestoreEntry_whereItFits(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let locale = Locale(identifier: language)
            let room = Self.turnMovesWidth(panel: Layout.changesPanelDefaultWidth)
            let whole = Self.size(of: Self.wholeRestoreEntry(locale: locale), proposing: nil, language: language, settings: settings)
            #expect(whole.width <= room, "\(language)")
            let restoreOnly = TurnCardMoves(lineMove: nil, restore: .init(blocker: nil, ask: {}))
            let size = Self.size(of: restoreOnly, proposing: room, language: language, settings: settings)
            #expect(abs(size.width - whole.width) < 0.5, "\(language): \(size.width) against \(whole.width)")
        }
    }

    /// "Unmark as Viewed" sits at the right end of the viewed line's own
    /// row, and at the panel's narrowest the rule, the words, the second
    /// rule, and the button still fit that one row, each rule keeping its
    /// least width, so the move never has to drop under the line.
    @Test(arguments: ["en", "ja"])
    func viewedLineHead_keepsUnmarkOnTheLine_atThePanelsNarrowest(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let room = Layout.changesPanelWidthRange.lowerBound - 2 * Layout.changesListInset - 2 * Layout.viewedLineInset
            let withUnmark = Self.size(of: ViewedLineHead(unmark: {}), proposing: 0, language: language, settings: settings)
            let alone = Self.size(of: ViewedLineHead(unmark: nil), proposing: 0, language: language, settings: settings)
            #expect(withUnmark.width <= room, "\(language): \(withUnmark.width) in \(room)")
            // The button is in the row, beside the words, not under them.
            #expect(withUnmark.width > alone.width, "\(language)")
            #expect(abs(withUnmark.height - Layout.secondaryButtonCompactHeight) < 0.5, "\(language): \(withUnmark.height)")
        }
    }

    /// Returns each move a card offers beside its restore, the restore alone,
    /// and a restore held back. "Mark as Unviewed from Here" is under a viewed
    /// turn, so it comes with the viewed mark ahead of it.
    private static func turnCardMoves(locale: Locale, movesOtherLines: Bool = false) -> [TurnCardMoves] {
        let actions: [ChangesPanelModel.RowAction] = [.markViewedThrough, .markUnviewedFrom]
        let beside = actions.map { action in
            TurnCardMoves(
                lineMove: .init(
                    title: ChangesPanelText.action(action, movesOtherLines: movesOtherLines, locale: locale),
                    shortTitle: ChangesPanelText.shortAction(action, movesOtherLines: movesOtherLines, locale: locale)
                ) {},
                restore: .init(blocker: nil, ask: {}),
                isViewed: action == .markUnviewedFrom
            )
        }
        return beside + [
            TurnCardMoves(lineMove: nil, restore: .init(blocker: nil, ask: {})),
            TurnCardMoves(lineMove: nil, restore: .init(blocker: .turnRunning, ask: {}))
        ]
    }

    private static func wholeRestoreEntry(locale: Locale) -> some View {
        RestoreEntryButton(title: RestoreText.entry(locale: locale), blocker: nil, ask: {})
    }
}
