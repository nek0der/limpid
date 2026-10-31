// ChangesPanelCardFitTests.swift
// Weir — a turn card keeps to its two lines and the viewed line's Unmark stays on its row, down to the changes panel's narrowest.

import AppKit
import SwiftUI
import Testing
@testable import Weir
@testable import WeirDomain

extension SupervisionFootBarTests {

    // MARK: - A turn card across the changes panel

    /// The room a card's words have in a panel `width` wide: the list's
    /// inset on both sides, the card's own, and its first column.
    private static func turnWordsWidth(panel width: CGFloat, hasConversation: Bool) -> CGFloat {
        width - 2 * Layout.changesListInset - Layout.turnCardInsets.leading - Layout.turnCardInsets.trailing
            - Layout.turnFirstColumnWidth(hasConversation: hasConversation, digits: 4) - Layout.turnColumnSpacing
    }

    /// The widest facts a card shows: a large diff, three marks after more,
    /// a short count of over a million with its unit, and a turn over an
    /// hour.
    private static func widestFacts(locale: Locale) -> ChangesPanelText.Facts {
        let marks = (0..<3).map { CheckMark(exitCode: $0 % 2, isFiltered: false) }
        return ChangesPanelText.Facts(
            files: 128,
            changes: ChangesPanelText.diffRuns(files: nil, added: 12345, removed: 6789, locale: locale),
            checks: [ReceiptRun(text: "…", role: .quiet)] + marks.map {
                ReceiptRun(text: $0.hasFailed ? "✗" : "✓", role: $0.hasFailed ? .failed : .plain)
            },
            tokens: ChangesPanelText.tokens(
                TurnUsage(inputTokens: 1_250_000, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 0, isPartial: true),
                locale: locale
            ),
            duration: ChangesPanelText.compactDuration(3725, locale: locale)
        )
    }

    /// At the panel's narrowest, with the conversation's badge widening
    /// the first column, the card's second line keeps to one line inside
    /// the card: the changes give way, the columns after them do not.
    @Test(arguments: ["en", "ja"])
    func turnFacts_keepToOneLine_atThePanelsNarrowest(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let locale = Locale(identifier: language)
            let room = Self.turnWordsWidth(panel: Layout.changesPanelWidthRange.lowerBound, hasConversation: true)
            let line = TurnFactsLine(facts: Self.widestFacts(locale: locale))
            let size = Self.size(of: line, proposing: room, language: language, settings: settings)
            let caption = Text(verbatim: "+1").font(.supervision(.caption))
            let oneLine = Self.size(of: caption, proposing: nil, language: language, settings: settings)
            #expect(size.width <= room + 0.5, "\(language): \(size.width) in \(room)")
            #expect(size.height < oneLine.height * 1.5, "\(language): \(size.height) against a line of \(oneLine.height)")
            // A common card ("2 +47 −9", three marks, "84K tok", "11m")
            // keeps its changes whole in that room: the columns after them,
            // as narrow as they go, leave the changes their own width.
            let marks = [ReceiptRun(text: "✗", role: .failed), ReceiptRun(text: "✗", role: .failed), ReceiptRun(text: "✓", role: .plain)]
            let columns = ChangesPanelText.Facts(
                files: 2,
                changes: [],
                checks: marks,
                tokens: ChangesPanelText.compactCount(84000, locale: locale),
                duration: ChangesPanelText.compactDuration(662, locale: locale)
            )
            let fixed = Self.size(of: TurnFactsLine(facts: columns), proposing: 0, language: language, settings: settings)
            let diff = Self.size(
                of: ReceiptRunsText(runs: ChangesPanelText.diffRuns(files: nil, added: 47, removed: 9, locale: locale), size: .caption),
                proposing: nil,
                language: language,
                settings: settings
            )
            // The file count beside its glyph, as the changes column draws
            // it ahead of the diff; at no width it is cut out of `fixed`.
            let files = Self.size(
                of: HStack(spacing: Layout.spaceHairline) {
                    Image(systemName: "doc").font(.supervision(.glyph))
                    Text(verbatim: "2").font(.supervision(.caption)).padding(.trailing, Layout.spaceHairline)
                },
                proposing: nil,
                language: language,
                settings: settings
            )
            let changes = files.width + Layout.spaceHairline + diff.width
            #expect(fixed.width + changes <= room, "\(language): \(fixed.width) + \(changes) in \(room)")
        }
    }

    /// The glyph moves stand where the time is, the slot widening to take
    /// them, so the prompt keeps most of its line at the panel's narrowest
    /// even while they show.
    @Test(arguments: ["en", "ja"])
    func turnCardMoves_takeLittleOfThePromptsLine(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let locale = Locale(identifier: language)
            let reason = RestoreText.blocker(.turnRunning, locale: locale)
            let moves = TurnCardMoves(
                moves: [
                    .init(
                        kind: .line(.markUnviewedFrom),
                        title: ChangesPanelText.action(.markUnviewedFrom, locale: locale),
                        detail: nil,
                        blocker: nil
                    ),
                    .init(kind: .restore, title: RestoreText.entry(locale: locale), detail: nil, blocker: reason)
                ],
                perform: { _ in }
            )
            let size = Self.size(of: moves, proposing: nil, language: language, settings: settings)
            let room = Self.turnWordsWidth(panel: Layout.changesPanelWidthRange.lowerBound, hasConversation: true)
            #expect(size.width <= room / 3, "\(language): \(size.width) of \(room)")
            #expect(size.height <= Layout.turnMoveHeight + 0.5, "\(language): the moves keep to the prompt's line")
            // The room the time's slot keeps for them is as wide as they are,
            // so the glyphs never stand over the prompt.
            let slot = Self.size(of: TurnCardMovesRoom(moves: moves.moves), proposing: nil, language: language, settings: settings)
            #expect(abs(slot.width - size.width) < 0.5, "\(language): \(slot.width) for \(size.width)")
        }
    }

    /// A card's first line is as tall while its moves show as at rest: the
    /// time's slot widens to take them but never grows the line, so a card
    /// the pointer or the keyboard comes onto keeps its height and the cards
    /// under it stay where they are.
    @Test(arguments: ["en", "ja"])
    func cardFit_movesShown_keepTheFirstLinesHeight(language: String) {
        let locale = Locale(identifier: language)
        let moves = [
            TurnCardMove(
                kind: .line(.markViewedThrough),
                title: ChangesPanelText.action(.markViewedThrough, locale: locale),
                detail: nil,
                blocker: nil
            ),
            TurnCardMove(kind: .restore, title: RestoreText.entry(locale: locale), detail: nil, blocker: nil)
        ]
        func line(showsMoves: Bool) -> CGSize {
            let view = HStack(alignment: .firstTextBaseline, spacing: Layout.spaceSnug) {
                Text(verbatim: "Add a function count(items) to cart.py")
                    .font(.supervision(.label, weight: .medium))
                TurnCardTimeSlot(moves: moves, time: "11:44", showsMoves: showsMoves)
            }
            return NSHostingController(rootView: view.fixedSize().environment(\.locale, locale))
                .sizeThatFits(in: CGSize(width: 4000, height: 4000))
        }
        let rest = line(showsMoves: false)
        let shown = line(showsMoves: true)
        let room = NSHostingController(rootView: TurnCardMovesRoom(moves: moves)).sizeThatFits(in: CGSize(width: 4000, height: 4000))

        let slot = { (showsMoves: Bool) in
            NSHostingController(rootView: TurnCardTimeSlot(moves: moves, time: "11:44", showsMoves: showsMoves).environment(
                \.locale,
                locale
            ))
            .sizeThatFits(in: CGSize(width: 4000, height: 4000))
        }

        #expect(
            abs(slot(true).height - slot(false).height) < 0.5,
            "\(language): the slot \(slot(true).height) against \(slot(false).height)"
        )
        #expect(abs(shown.height - rest.height) < 0.5, "\(language): \(shown.height) against \(rest.height)")
        #expect(shown.width >= rest.width - 0.5 + max(0, room.width - Self.timeWidth), "\(language): the slot still takes the moves' width")
    }

    /// "11:44" in the time's face, for the slot's width at rest.
    private static var timeWidth: CGFloat {
        NSHostingController(rootView: Text(verbatim: "11:44").font(.supervision(.caption).monospacedDigit()).fixedSize())
            .sizeThatFits(in: CGSize(width: 4000, height: 4000)).width
    }

    /// How big a card's first column lays out, offered all the room it asks.
    private static func labelSize(_ label: TurnCardLabel) -> CGSize {
        NSHostingController(rootView: label.environment(\.locale, Locale(identifier: "en")))
            .sizeThatFits(in: CGSize(width: 4000, height: 4000))
    }

    /// The tight size of the label's contents, without the column's fixed
    /// width, so a change in what it draws shows.
    private static func contentSize(_ label: TurnCardLabel) -> CGSize {
        NSHostingController(rootView: label.content.fixedSize().environment(\.locale, Locale(identifier: "en")))
            .sizeThatFits(in: CGSize(width: 4000, height: 4000))
    }

    /// An unviewed turn's number is a filled pill whose padding is drawn
    /// around the number rather than laid out in the column, so the card is
    /// as tall as a viewed one's and its number stands where a viewed one's
    /// does. Even "T1000" keeps its pill short of the prompt and within the
    /// card's inset.
    @Test(arguments: [false, true])
    func cardFit_unviewedPill_keepsRowHeight(hasConversation: Bool) {
        var choice = ConversationChoice(conversation: TurnSummaryFixture.conversation, ordinal: 2, unviewedCount: 1)
        choice.identity = 1
        let conversation = hasConversation ? choice : nil
        for number in [7, 1000] {
            let viewed = Self.contentSize(TurnCardLabel(number: number, isUnviewed: false, conversation: conversation))
            let unviewed = Self.contentSize(TurnCardLabel(number: number, isUnviewed: true, conversation: conversation))
            #expect(abs(unviewed.height - viewed.height) < 0.5, "T\(number): \(unviewed.height) against \(viewed.height)")
            #expect(abs(unviewed.width - viewed.width) < 0.5, "T\(number): \(unviewed.width) against \(viewed.width)")
            let column = Self.labelSize(TurnCardLabel(number: number, isUnviewed: true, conversation: conversation))
            #expect(abs(column.height - viewed.height) < 0.5, "T\(number): the column is as tall as its contents")
        }
        let padding = Layout.turnUnviewedPillPadding.width
        for label in ["T7", "T1000"] {
            let number = ceil((label as NSString).size(withAttributes: [.font: Layout.turnNumberFont]).width)
            let column = Layout.turnFirstColumnWidth(hasConversation: hasConversation, digits: label.count - 1)
            #expect(number + padding <= column, "\(label): \(number) + \(padding) in \(column)")
        }
        #expect(padding <= Layout.turnCardInsets.leading)
    }

    /// The conversation's bar before its badge leaves the first column as tall
    /// as a single-conversation row's and within its width; a conversation
    /// with no color draws its badge alone.
    @Test func cardFit_identityBar_keepsRowHeight() {
        var colored = ConversationChoice(conversation: TurnSummaryFixture.conversation, ordinal: 2, unviewedCount: 1)
        colored.identity = 3
        var plain = colored
        plain.identity = nil
        let withBar = Self.contentSize(TurnCardLabel(number: 7, isUnviewed: true, conversation: colored))
        let alone = Self.contentSize(TurnCardLabel(number: 7, isUnviewed: true, conversation: plain))
        #expect(abs(withBar.height - alone.height) < 0.5, "\(withBar.height) against \(alone.height)")
        #expect(withBar.width > alone.width, "the bar is drawn")
        // Drawn out to the pill's start, so the column holds it less that.
        let column = Layout.turnFirstColumnWidth(hasConversation: true, digits: 1)
        #expect(withBar.width - Layout.turnUnviewedPillPadding.width <= column + 0.5, "\(withBar.width)")
    }

    /// The duration is the first fact to go: the list drops it from every
    /// card once a card's changes would not read whole beside it, and keeps
    /// it until a card has said how wide it is.
    @Test func theDuration_givesWay_whenTheChangesWouldNotFitWhole() {
        var columns = TurnFactColumns(checks: 20, tokens: 50, duration: 40, changes: 60, line: 300)
        #expect(columns.showsDuration)
        columns.line = 150
        #expect(!columns.showsDuration)
        #expect(TurnFactColumns().showsDuration)
        // The narrowest line and the widest changes decide, across cards.
        let wide = TurnFactColumns(changes: 200, line: 400)
        let narrow = TurnFactColumns(changes: 10, line: 250)
        #expect(wide.widest(narrow).line == 250)
        #expect(!wide.widest(narrow).showsDuration)
        // A card of words alone takes the checks' column too, so words that
        // fit there keep the duration.
        let words = TurnFactColumns(checks: 28, tokens: 44, duration: 30, words: 100, line: 200)
        #expect(words.showsDuration)
        #expect(!TurnFactColumns(checks: 28, tokens: 44, duration: 30, changes: 100, line: 200).showsDuration)
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
}
