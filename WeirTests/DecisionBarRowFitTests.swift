// DecisionBarRowFitTests.swift
// Weir — the decision bar's row inside its foot bar, and its words and buttons across the pane, narrowing in turn.

import AppKit
import SwiftUI
import Testing
@testable import Weir
@testable import WeirDomain

extension SupervisionFootBarTests {
    /// The decision bar's own row, from its model: a stop with its resume,
    /// its count and its ⋯; unread turns with their buttons; the bar at rest.
    @Test func decisionBarRow_fitsInsideTheFootBar() throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let hint = PrimaryKeyHint(defaults: nil)
            #expect(hint.isShown)
            for model in Self.decisionBarModels() {
                for size in Self.typeSizes {
                    let row = DecisionBarRow(model: model, paneID: Self.pane, receiptHelp: nil, canStartNew: true, onShowNext: {})
                        .environment(settings)
                        .environment(hint)
                        .environment(\.primaryActionHandler, Self.actions)
                    let height = Self.height(of: row, typeSize: size)
                    #expect(height > 0)
                    #expect(height <= Self.roomInsideRules, "\(model.text)")
                }
            }
        }
    }

    /// From 160pt to 400pt wide, the sentence and where to answer share the
    /// width the row is given, and never ask for more.
    @Test(arguments: ["en", "ja"], [160, 200, 280, 400] as [CGFloat])
    func decisionBarRow_withWhereToAnswer_isNoWiderThanThePane(language: String, width: CGFloat) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let locale = Locale(identifier: language)
            let long = "/Users/me/repositories/weir/.claude/worktrees/supervision-ui/Weir/Core/Domain/PromptWait.swift"
            let waits = [
                PromptWait(detail: "Write: \(long)", kind: .approval, tool: "Write"),
                PromptWait(detail: "Which of these two branches should the release go out from?", kind: .question, tool: nil),
                PromptWait(detail: "Allow the agent to reach \(long)?")
            ]
            for wait in waits {
                let item = AttentionItem.testPrompt(wait, pane: Self.pane)
                let model = DecisionBarModel(content: .make(.init(items: [item])), locale: locale)
                let row = DecisionBarRow(model: model, paneID: Self.pane, receiptHelp: nil, canStartNew: true, onShowNext: {})
                    .environment(\.primaryActionHandler, Self.actions)
                let size = Self.size(of: row, proposing: width, language: language, settings: settings)
                #expect(size.width <= width, "\(language) at \(width): \(model.text)")
            }
        }
    }

    /// Where to answer is whole while the sentence keeps its floor beside
    /// it, takes its short form once it would not, and the two never ask
    /// for more than they are given.
    @Test func decisionBarWords_chooseTheWholeInstruction_thenItsShortForm() {
        let full = "Answer in the terminal"
        let short = "Answer in terminal"
        func words(_ sentence: String, _ width: CGFloat) -> CGFloat {
            let view = DecisionBarWordsLayout(spacing: 4, sentenceFloor: 80) {
                Self.wordsText(sentence)
                ViewThatFits(in: .horizontal) {
                    Self.wordsText(full).fixedSize()
                    Self.wordsText(short)
                }
            }
            return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 32)).width
        }
        func ideal(_ text: String) -> CGFloat {
            NSHostingController(rootView: Self.wordsText(text).fixedSize()).sizeThatFits(in: CGSize(width: 4000, height: 32)).width
        }
        // A sentence shorter than its floor shows which form was chosen:
        // the row is as wide as the sentence, the gap, and that form.
        let hi = ideal("Hi")
        let fullWidth = ideal(full)
        let shortWidth = ideal(short)
        #expect(abs(words("Hi", hi + 4 + fullWidth + 1) - (hi + 4 + fullWidth)) < 1.5, "room for the whole one")
        #expect(abs(words("Hi", hi + 4 + shortWidth + 10) - (hi + 4 + shortWidth)) < 1.5, "room for the short one only")
        // A long sentence: its floor of 80 decides. With the floor and the
        // whole instruction it fills the row; without, it still does not
        // ask for more, down to a pane narrower than both.
        let sentence = "Claude wants to change files in the repository."
        for width in [80 + 4 + fullWidth, 80 + 4 + fullWidth - 20, 80 + 4 + shortWidth, 140, 100, 60] {
            #expect(words(sentence, width) <= width + 0.5, "\(width)")
        }
    }

    // MARK: - The decision bar's buttons across the pane

    /// Each fit asks for no more than the one before it, and folding makes
    /// room on unread turns, where "Review Unviewed" goes into the ⋯. Unread
    /// turns on their own keep it in the row in a 1280×800 window's column
    /// (580pt), and every bar keeps its buttons, in `minimal`, in one of
    /// two panes side by side in the review's narrowest column. Widths are
    /// with the bar's insets (`DecisionBarModel.Fit`).
    @Test(arguments: ["en", "ja"])
    func decisionBarFits_narrowInTurn(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let locale = Locale(identifier: language)
            let models = Self.decisionBarsWithButtons(locale: locale)
            for model in models {
                let fits = model.fits(locale: locale)
                let widths = Self.fitWidths(model, fits: fits, language: language, settings: settings)
                for (wider, narrower) in zip(widths, widths.dropFirst()) {
                    #expect(narrower < wider, "\(language) \(fits): \(widths)")
                }
                let minimal = Self.fitWidths(model, fits: [.minimal], language: language, settings: settings)
                #expect(minimal[0] <= Self.halfOfTheNarrowestReview, "\(language): \(model.text)")
            }
            let unread = try #require(models.first)
            let full = Self.fitWidths(unread, fits: [.full], language: language, settings: settings)
            #expect(full[0] <= 580, "\(language): \(full)")
        }
    }

    /// One of two panes side by side in the review's narrowest column, as
    /// a split lays them out (about 197pt).
    private nonisolated static let halfOfTheNarrowestReview: CGFloat = 196

    /// The width each of `fits` asks for at its ideal, with the bar's
    /// insets.
    private static func fitWidths(
        _ model: DecisionBarModel,
        fits: [DecisionBarModel.Fit],
        language: String,
        settings: SettingsStore
    ) -> [CGFloat] {
        let insets = Layout.footBarLeadingInset + Layout.footBarTrailingInset
        return fits.map { fit in
            let row = decisionBarRow(model, fits: [fit]).fixedSize(horizontal: true, vertical: false)
            return size(of: row, proposing: nil, language: language, settings: settings).width + insets
        }
    }

    /// From one of two panes side by side in the review's narrowest column
    /// (about 197pt) to the session's column in a 1280×800 window, the row
    /// with its buttons takes a fit no wider than the room inside the
    /// bar's insets, rather than push its buttons past the pane's edge.
    /// Measured on the row, as the bar itself would cut a wider row at the
    /// pane's edge.
    @Test(arguments: ["en", "ja"], [halfOfTheNarrowestReview, 200, WeirLayout.reviewMinWidth, 480, 580])
    func decisionBarRow_withButtons_isNoWiderThanThePane(language: String, width: CGFloat) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let room = width - Layout.footBarLeadingInset - Layout.footBarTrailingInset
            for model in Self.decisionBarsWithButtons(locale: Locale(identifier: language)) {
                let size = Self.size(of: Self.decisionBarRow(model), proposing: room, language: language, settings: settings)
                #expect(size.width <= room, "\(language) at \(width): \(model.text)")
            }
        }
    }

    /// In a pane too narrow for any button, as narrow as a split allows
    /// (60 to 80pt), the row takes the fit with its words alone: the least
    /// fit with buttons asks for more than the room, and the row laid out
    /// asks for no more. A button past the pane's edge would be cut from
    /// sight but still take clicks.
    @Test(arguments: ["en", "ja"], [TerminalSettings.minPaneSizeRange.lowerBound, TerminalSettings.defaultMinPaneSize])
    func decisionBarRow_tooNarrowForAnyButton_keepsOnlyItsWords(language: String, paneWidth: Double) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let width = CGFloat(paneWidth)
            let locale = Locale(identifier: language)
            let room = width - Layout.footBarLeadingInset - Layout.footBarTrailingInset
            for model in Self.decisionBarsWithButtons(locale: locale) {
                #expect(model.fits(locale: locale).last == .wordsOnly)
                let minimal = Self.size(
                    of: Self.decisionBarRow(model, fits: [.minimal]),
                    proposing: room,
                    language: language,
                    settings: settings
                )
                #expect(minimal.width > room, "\(language) at \(width): \(model.text)")
                let size = Self.size(of: Self.decisionBarRow(model), proposing: room, language: language, settings: settings)
                #expect(size.width <= room, "\(language) at \(width): \(model.text)")
            }
        }
    }

    /// The bar cuts a row wider than the pane at the pane's edge: what the
    /// row would draw past the edge is not drawn there. Each bar's least
    /// fit with buttons, wider than a pane at the narrowest a split allows,
    /// stands for a row with no narrower fit.
    @Test(arguments: ["en", "ja"])
    func decisionBar_narrowerThanEveryFit_isCutAtThePanesEdge(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let width = CGFloat(TerminalSettings.minPaneSizeRange.lowerBound)
            let canvas: CGFloat = 400
            for model in Self.decisionBarsWithButtons(locale: Locale(identifier: language)) {
                let row = Self.decisionBarRow(model, fits: [.minimal])
                let unclipped = Self.size(
                    of: row.fixedSize(horizontal: true, vertical: false),
                    proposing: nil,
                    language: language,
                    settings: settings
                )
                #expect(unclipped.width > width, "\(language): \(model.text)")
                let view = ZStack(alignment: .leading) {
                    Color.white
                    SupervisionFootBar(fill: DecisionBarRow.fill(model.tone), rule: DecisionBarRow.rule(model.tone)) {
                        row
                    }
                    .frame(width: width)
                }
                .frame(width: canvas, height: Layout.footBarHeight)
                .environment(settings)
                .environment(PrimaryKeyHint(defaults: nil))
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                let bitmap = NSBitmapImageRep(cgImage: image)
                // Past the pane's edge, only the white behind the bar.
                let drawn = stride(from: Int(width) + 1, to: Int(canvas), by: 1).flatMap { x in
                    stride(from: 2, to: image.height - 2, by: 2).compactMap { y in
                        bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB).map { (x, $0) }
                    }
                }
                let marked = drawn.filter { _, color in
                    min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9
                }
                #expect(marked.isEmpty, "\(language): \(model.text) drawn at x \(marked.first?.0 ?? -1)")
            }
        }
    }

    /// Unread turns with every button the bar gives them (a receipt,
    /// "Mark as Viewed" with ⌘⏎, "Review Unviewed", and the restore's ⋯),
    /// the same with a stop also pending, a stop with its resume and its
    /// ⋯, and the line after Mark as Viewed with its Undo.
    private static func decisionBarsWithButtons(locale: Locale) -> [DecisionBarModel] {
        let check = CheckSummary(command: "make test", isFiltered: true, exitCode: 1)
        let turn = UnreadTurn(
            turnID: TurnID("T5"),
            numbers: 5...7,
            changes: .changed(files: 12, added: 1294, removed: 302),
            check: check,
            conversation: TurnSummaryFixture.conversation
        )
        var queue = AttentionQueue()
        queue.insert(
            id: .unread(turn.turnID),
            kind: .unread(turn),
            subject: .runtime(id: "r", provider: .claude, paneID: pane, tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let unread = queue.items[0]
        let stop = AttentionItem.testStop(pane: pane)
        let undo = ViewedLineUndo(conversation: TurnSummaryFixture.conversation, changeID: UUID())
        return [
            DecisionBarModel(content: .make(.init(items: [unread])), locale: locale),
            DecisionBarModel(content: .make(.init(items: [unread, stop], selected: unread.id)), locale: locale),
            DecisionBarModel(content: .make(.init(items: [stop], stopResumes: [stop.id: .available])), locale: locale),
            DecisionBarModel(content: .make(.init(done: .init(result: .markedViewed(undo), next: nil))), locale: locale)
        ]
    }

    private static func decisionBarRow(_ model: DecisionBarModel, fits: [DecisionBarModel.Fit]? = nil) -> some View {
        DecisionBarRow(model: model, paneID: pane, receiptHelp: nil, canStartNew: true, onShowNext: {}, fits: fits)
            .environment(\.primaryActionHandler, actions)
            .environment(\.restoreHandler, restoreHandler)
    }

    private static func wordsText(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12.5)).lineLimit(1)
    }

    static func decisionBarModels() -> [DecisionBarModel] {
        let stop = AttentionItem.testStop(pane: pane)
        let unread = AttentionItem.testUnread(pane: pane)
        let english = Locale(identifier: "en")
        let undo = ViewedLineUndo(conversation: TurnSummaryFixture.conversation, changeID: UUID())
        return [
            DecisionBarModel(
                content: .make(.init(items: [stop, unread], stopResumes: [stop.id: .available])),
                locale: english
            ),
            DecisionBarModel(content: .make(.init(items: [unread])), locale: english),
            DecisionBarModel(content: .make(.init()), locale: english),
            // Right after Mark as Viewed: the quiet check, the sentence, and Undo.
            DecisionBarModel(content: .make(.init(done: .init(result: .markedViewed(undo), next: nil))), locale: english)
        ]
    }
}
