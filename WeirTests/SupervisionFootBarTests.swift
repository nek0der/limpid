// SupervisionFootBarTests.swift
// Weir — each column's foot bar holds its row inside its rules, and the three bars share one line in the window.

// The decision bar's row is checked in `DecisionBarRowFitTests`, and a turn card's moves in `ChangesPanelCardFitTests`.

import AppKit
import SwiftUI
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Supervision foot bar", .hostsWindows)
@MainActor
struct SupervisionFootBarTests {
    typealias Layout = WeirLayout.Supervision

    /// Beside the terminal the panel runs to the body's bottom; laid over
    /// it, the panel stops one foot bar short, above the session's foot
    /// bar, and runs to the bottom when the session shows none.
    @Test func theOverlaidPanel_stopsOneFootBarAboveTheBottom_onlyOverAFootBar() {
        #expect(ChangesPanelPlacement.bottomInset(isOver: false, sessionShowsFootBar: false) == 0)
        #expect(ChangesPanelPlacement.bottomInset(isOver: false, sessionShowsFootBar: true) == 0)
        #expect(ChangesPanelPlacement.bottomInset(isOver: true, sessionShowsFootBar: false) == 0)
        #expect(ChangesPanelPlacement.bottomInset(isOver: true, sessionShowsFootBar: true) == Layout.footBarHeight)
    }

    // MARK: - The session's foot under an overlaid panel

    private typealias Bottom = ChangesPanelPlacement.SessionBottom

    private static func showsFootBar(_ bottom: Bottom, barsIn panes: Set<UUID> = []) -> Bool {
        ChangesPanelPlacement.sessionShowsFootBar(bottom) { panes.contains($0) }
    }

    /// A tab of two panes side by side, `leading` | `trailing`.
    private static func sideBySide(_ leading: UUID, _ trailing: UUID) -> SplitTree {
        SplitTree(root: .split(PaneSplit(direction: .horizontal, ratio: 0.5, first: .leaf(id: leading), second: .leaf(id: trailing))))
    }

    /// No tab open, as in a project's root with none: nothing at the foot.
    @Test func noTab_showsNoFootBar() {
        #expect(!Self.showsFootBar(Bottom(tree: nil)))
        #expect(!Self.showsFootBar(Bottom(isChoosingProject: true)))
        // A window showing the projects to open draws no session at all.
        #expect(!Self.showsFootBar(Bottom(isChoosingProject: true, isReviewShown: true, hasLaunchBar: true)))
    }

    /// A shell pane has no decision bar.
    @Test func aShellPaneOnly_showsNoFootBar() {
        #expect(!Self.showsFootBar(Bottom(tree: SplitTree(leafID: UUID()))))
    }

    /// An agent's pane draws its decision bar at the session's foot.
    @Test func anAgentPane_showsItsDecisionBar() {
        let agent = UUID()
        #expect(Self.showsFootBar(Bottom(tree: SplitTree(leafID: agent)), barsIn: [agent]))
    }

    /// Side by side, a bar under the leading pane alone still counts: how
    /// far the panel reaches into the split changes with every width, and
    /// the bar's buttons stay in reach at each of them.
    @Test func aSplitWithABarOnlyUnderTheLeadingPane_showsAFootBar() {
        let leading = UUID()
        let trailing = UUID()
        #expect(Self.showsFootBar(Bottom(tree: Self.sideBySide(leading, trailing)), barsIn: [leading]))
        #expect(!Self.showsFootBar(Bottom(tree: Self.sideBySide(leading, trailing))))
    }

    /// Stacked, only the lower pane's bar is at the foot; the upper one's
    /// is mid-session. Zoomed, only the zoomed pane is drawn.
    @Test func onlyPanesOnTheBottomEdge_count() {
        let upper = UUID()
        let lower = UUID()
        let stacked = SplitTree(root: .split(PaneSplit(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(id: upper),
            second: .leaf(id: lower)
        )))
        #expect(!Self.showsFootBar(Bottom(tree: stacked), barsIn: [upper]))
        #expect(Self.showsFootBar(Bottom(tree: stacked), barsIn: [lower]))
        #expect(Self.showsFootBar(Bottom(tree: stacked, zoomedLeafID: upper), barsIn: [upper]))
        #expect(!Self.showsFootBar(Bottom(tree: stacked, zoomedLeafID: upper), barsIn: [lower]))
        // A zoom of a pane gone from the tab draws the split.
        #expect(Self.showsFootBar(Bottom(tree: stacked, zoomedLeafID: UUID()), barsIn: [lower]))
    }

    /// The review tab's band, and a new session's setup line, run across
    /// the foot whatever the panes under them.
    @Test func theReviewBandAndTheLaunchBar_areFootBars() {
        #expect(Self.showsFootBar(Bottom(isReviewShown: true, tree: SplitTree(leafID: UUID()))))
        #expect(Self.showsFootBar(Bottom(isReviewShown: true, tree: nil)))
        #expect(Self.showsFootBar(Bottom(hasLaunchBar: true, tree: nil)))
    }

    // MARK: - Each row inside its bar

    /// The sidebar's foot: the scratch row's fill, as tall as its token and
    /// clear of the rule.
    @Test func scratchRow_fitsInsideTheFootBar() {
        for isActive in [false, true] {
            for size in Self.typeSizes {
                let row = ScratchRowView(
                    row: .test(.test(container: .loose), activeContainer: isActive ? .loose : nil),
                    startFolder: URL(fileURLWithPath: "/tmp"),
                    now: .now,
                    isKeyboardSelected: isActive,
                    actions: SessionRowActions()
                ) {}
                let height = Self.height(of: row, typeSize: size)
                #expect(height == Layout.scratchRowHeight)
                #expect(height <= Self.roomInsideRules)
            }
        }
    }

    /// The review's band's own row: comments to insert with their
    /// destination, "Mark as Viewed" primary with its key, and the row while
    /// the files are read.
    @Test func reviewBandRow_fitsInsideTheFootBar() throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let hint = PrimaryKeyHint(defaults: nil)
            for row in Self.bandRows() {
                for size in Self.typeSizes {
                    let view = row
                        .environment(settings)
                        .environment(hint)
                    let height = Self.height(of: view, typeSize: size)
                    #expect(height > 0)
                    #expect(height <= Self.roomInsideRules)
                }
            }
        }
    }

    // MARK: - The review's band across its column

    /// Short of room, the band takes a narrower fit rather than ask the
    /// column for more than it has, and so never widens the review above
    /// it past the column's edge. In English and Japanese, at the review's
    /// narrowest (`reviewMinWidth`) and at the session's column in a
    /// 1280×800 window, the bar is no wider than the width it is given;
    /// and narrower than any fit, at 320pt, it cuts the destination's name
    /// rather than push Close out of the column.
    @Test(arguments: ["en", "ja"], [320, WeirLayout.reviewMinWidth, 580])
    func reviewBand_isNoWiderThanItsColumn(language: String, width: CGFloat) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            for row in Self.bandRows() {
                let bar = SupervisionFootBar(fill: ReviewTabBandRow.fill(row.tone), rule: ReviewTabBandRow.rule(row.tone)) {
                    row
                }
                let size = Self.size(of: bar, proposing: width, language: language, settings: settings)
                #expect(size.width <= width, "\(language) at \(width)")
                #expect(size.height == Layout.footBarHeight)
            }
        }
    }

    /// Each fit asks for no more than the one before it. The full row,
    /// with the status and "Review Destination", shows from
    /// `fullFitWidth` (a tab writing nowhere shows there its reason,
    /// "Choose Destination…", and Insert's count); Close stays in words in a 1280×800 window's column
    /// (580pt); and the narrowest fits the review's narrowest width, so
    /// the band has a fit for every width the review is given. Widths are
    /// with the bar's insets.
    @Test(arguments: ["en", "ja"])
    func reviewBand_fitsNarrowInTurn_downToTheReviewsMinimum(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let insets = Layout.footBarLeadingInset + Layout.footBarTrailingInset
            for row in Self.bandRows() {
                let widths = ReviewTabBandRow.Fit.allCases.map { fit in
                    let line = ReviewTabBandRow.Line(row: row, fit: fit).fixedSize(horizontal: true, vertical: false)
                    return Self.size(of: line, proposing: nil, language: language, settings: settings).width + insets
                }
                for (wider, narrower) in zip(widths, widths.dropFirst()) {
                    #expect(narrower <= wider, "\(language): \(widths)")
                }
                let byFit = Dictionary(uniqueKeysWithValues: zip(ReviewTabBandRow.Fit.allCases, widths))
                // A tab writing nowhere keeps Insert's count while the row
                // has room, so its full row is wider; from `fullFitWidth`
                // it still shows the count, with the status in the tag's
                // tooltip.
                let isChoosing = row.insert?.destination.status.offersChoice == true
                let full = try #require(byFit[isChoosing ? .withoutStatus : .full])
                let compact = try #require(byFit[.compact])
                let narrowest = try #require(byFit[.narrowest])
                #expect(full <= Self.fullFitWidth, "\(language): \(widths)")
                #expect(compact <= 580, "\(language): \(widths)")
                #expect(narrowest <= WeirLayout.reviewMinWidth, "\(language): \(widths)")
            }
        }
    }

    /// The changes panel's foot with each move it can hold.
    @Test func changesPanelFootButton_fitsInsideTheFootBar() {
        for action in Self.footActions {
            for size in Self.typeSizes {
                let button = CommitAndPRFootButton(action: action, perform: { _ in })
                let height = Self.height(of: button, typeSize: size)
                #expect(height > 0)
                #expect(height <= Self.roomInsideRules, "\(String(describing: action))")
            }
        }
    }

    /// The changes panel's foot bar is there only with a move to hold: an
    /// empty bar lined up nothing, and laid over the terminal it was only
    /// a band of dead space under Commit & PR.
    @Test func changesPanelFootBar_isDrawnOnlyWithAMove() {
        for action in Self.footActions {
            let bar = CommitAndPRFootBar(action: action, perform: { _ in })
            #expect(Self.height(of: bar, typeSize: .large) == Layout.footBarHeight, "\(String(describing: action))")
        }
        #expect(Self.height(of: CommitAndPRFootBar(action: nil, perform: { _ in }), typeSize: .large) == 0)
    }

    // MARK: - The three columns in the window

    /// The sidebar's, the decision bar's, and the changes panel's foot bars,
    /// laid out as the window's body lays out its surfaces, end on the
    /// body's bottom, share one rule line, and center their rows on one
    /// line. Laid over the terminal, the panel's bar stands one bar higher.
    @Test(arguments: [false, true])
    func theThreeColumnsFootBars_shareOneLine(isPanelOver: Bool) async throws {
        try await withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let book = NamedFrameRecorder(space: Self.bodySpace)
            let model = try #require(Self.decisionBarModels().first)
            let view = HStack(spacing: Layout.surfaceGap) {
                Self.column(width: Layout.sidebarDefaultWidth) {
                    SidebarFootBar {
                        ScratchRowView(
                            row: .test(.test(container: .loose)),
                            startFolder: URL(fileURLWithPath: "/tmp"),
                            now: .now,
                            actions: SessionRowActions()
                        ) {}
                            .recordFrame(in: book, as: "sidebar.row")
                    }
                    .recordFrame(in: book, as: "sidebar")
                }
                Self.column(width: nil) {
                    DecisionBarFootBar(model: model, paneID: Self.pane, receiptHelp: nil, canStartNew: true, onShowNext: {})
                        .recordFrame(in: book, as: "session")
                }
                Self.column(width: Layout.changesPanelDefaultWidth) {
                    CommitAndPRFootBar(action: .createPullRequest(.available([])), perform: { _ in })
                        .recordFrame(in: book, as: "panel")
                }
                .padding(.bottom, ChangesPanelPlacement.bottomInset(isOver: isPanelOver, sessionShowsFootBar: true))
            }
            .coordinateSpace(.named(Self.bodySpace))
            .frame(width: 1200, height: 600)
            .environment(settings)
            .environment(PrimaryKeyHint(defaults: nil))
            .environment(\.primaryActionHandler, Self.actions)
            .environment(\.locale, Locale(identifier: "en"))

            let (window, host) = hostedInWindow(view, width: 1200, height: 600)
            defer { window.close() }
            let frames = await settledValue(in: host) { book.frames.count == 4 ? book.frames : nil }
            let sidebar = try #require(frames?["sidebar"])
            let session = try #require(frames?["session"])
            let panel = try #require(frames?["panel"])
            let scratch = try #require(frames?["sidebar.row"])

            for bar in [sidebar, session, panel] {
                #expect(bar.height == Layout.footBarHeight)
            }
            #expect(sidebar.maxY == 600)
            #expect(session.minY == sidebar.minY)
            #expect(scratch.midY == sidebar.midY)
            if isPanelOver {
                #expect(panel.minY == sidebar.minY - Layout.footBarHeight)
            } else {
                #expect(panel.minY == sidebar.minY)
                #expect(panel.midY == session.midY)
            }
        }
    }

    /// A failed setup grows its bar upward: what to do and the log stand
    /// above, and the line with the buttons stays the bar's bottom 32pt, on
    /// the line every column's foot bar is on and clear of a panel laid
    /// over the terminal.
    @Test func aFailedSetup_keepsItsButtonsInTheBottomFootBar() async throws {
        try await withTempDir { directory in
            let book = NamedFrameRecorder(space: Self.bodySpace)
            let view = SessionLaunchBarLayout(
                tag: "Stopped",
                isFailed: true,
                isInProgress: false,
                headline: "Setup",
                spokenHeadline: "Stopped, Setup",
                detail: "The setup command exited with status 1. Fix it in the project's settings, or skip it.",
                logTail: "npm ERR! code ENOENT\nnpm ERR! syscall open\nnpm ERR! path package.json"
            ) {
                Button("Retry") {}
                    .buttonStyle(SupervisionPrimaryButtonStyle())
                    .recordFrame(in: book, as: "buttons")
            }
            .recordFrame(in: book, as: "bar")
            .frame(width: 640)
            .coordinateSpace(.named(Self.bodySpace))
            .environment(SettingsStore(directory: directory))
            .environment(\.locale, Locale(identifier: "en"))

            let (window, host) = hostedInWindow(view, width: 640, height: 400)
            defer { window.close() }
            let frames = await settledValue(in: host) { book.frames.count == 2 ? book.frames : nil }
            let bar = try #require(frames?["bar"])
            let buttons = try #require(frames?["buttons"])

            // The detail and the log took room above the line.
            #expect(bar.height > Layout.footBarHeight + 30)
            // The buttons sit centered in the bar's bottom 32pt.
            #expect(buttons.midY == bar.maxY - Layout.footBarHeight / 2)
            #expect(buttons.minY >= bar.maxY - Layout.footBarHeight + Layout.footBarRuleWidth)
            #expect(buttons.maxY <= bar.maxY - Layout.footBarRuleWidth)
        }
    }

    // MARK: - Helpers

    static let pane = UUID()

    /// The widest the band's full row gets, with the bar's insets: the
    /// column from which the files' status and "Review Destination" show
    /// (`ReviewTabBandRow.Fit.full`).
    /// Measured at 831pt in English and 817pt in Japanese.
    private static let fullFitWidth: CGFloat = 840
    private static let bodySpace = "footBarTestBody"

    /// A row stays clear of the rule above it, and of the same width below
    /// it, so it stays centered on the bar's center line.
    static let roomInsideRules = Layout.footBarHeight - 2 * Layout.footBarRuleWidth

    /// The app sets its sizes in points and follows no Dynamic Type, so the
    /// largest size is here to show that a type size the system hands down
    /// cannot push a row onto the rules either.
    static let typeSizes: [DynamicTypeSize] = [.large, .accessibility5]

    private static let footActions: [CommitAndPRModel.FootAction] = [
        .showCurrentDiff,
        .createPullRequest(.available([.unpushedWillBePushed])),
        .createPullRequest(.blocked(.unviewedTurns(2))),
        .openPullRequest(PRInfoFixture.make(state: .open)),
        .openExternalTool(CommitAndPRModel.ExternalTool(name: "tig", command: "tig"))
    ]

    static let actions = PrimaryActionHandler(
        windowID: WindowID(),
        handle: { _, _ in false },
        perform: { _, _ in },
        undo: { _, _ in },
        startNewConversation: { _, _ in },
        showPartialChanges: { _, _ in },
        openReview: { _, _ in }
    )

    /// A window's restores that ask for any turn, so the bar's ⋯ offers
    /// the restore.
    static let restoreHandler = RestoreHandler(
        windowID: WindowID(),
        confirmation: { _, _ in nil },
        confirm: { _, _ in },
        cancel: { _ in },
        record: { _ in nil },
        journal: { _ in nil },
        undo: { _ in },
        isBusy: { _ in false },
        undoResult: { _ in nil },
        ask: { _ in },
        canAsk: { _ in true },
        paletteTurnNumber: { nil }
    )

    private static func bandRows() -> [ReviewTabBandRow] {
        let destination = ReviewDestination(paneID: pane, title: "Claude Code", foreground: "claude")
        let insert = ReviewTabBandRow.Insert(
            count: 3,
            canInsert: true,
            destination: ReviewTabDestinationMenu(
                choices: [ReviewTabModel.DestinationChoice(destination: destination, label: "Claude Code")],
                selectedPaneID: pane,
                status: .ready(destination),
                onChoose: { _ in }
            ),
            onInsert: {}
        )
        // The widest the band gets: no pane to write to, whose reason and
        // "Choose Destination…" are the longest it shows, under a long
        // scope's comments. Each reason the band can give.
        let conversation = ConversationChoice(conversation: TurnSummaryFixture.conversation, ordinal: 12, unviewedCount: 1)
        let statuses: [ReviewTabModel.DestinationStatus] = [.conversationPaneClosed(conversation), .paneClosed, .unchosen, .noPane]
        let closed = statuses.map { status in
            ReviewTabBandRow.Insert(
                count: 12,
                canInsert: false,
                destination: ReviewTabDestinationMenu(
                    choices: [ReviewTabModel.DestinationChoice(destination: destination, label: "Claude Code 2")],
                    selectedPaneID: nil,
                    status: status,
                    onChoose: { _ in }
                ),
                onInsert: {}
            )
        }
        let markViewed = ReviewTabModel.MarkViewed.includingChangesOutsideTurns(through: nil)
        let closedRows = closed.map { insert in
            ReviewTabBandRow(
                tone: .unread,
                status: .unviewedFiles(12),
                markViewed: .init(action: markViewed, isPrimary: false, isEnabled: true),
                insert: insert,
                onMarkViewed: {},
                onClose: {}
            )
        }
        return closedRows + [
            ReviewTabBandRow(
                tone: .unread,
                status: .unviewedFiles(3),
                markViewed: .init(action: markViewed, isPrimary: false, isEnabled: true),
                insert: insert,
                onMarkViewed: {},
                onClose: {}
            ),
            ReviewTabBandRow(
                tone: .muted,
                status: .allFilesViewed,
                markViewed: .init(action: markViewed, isPrimary: true, isEnabled: true),
                insert: nil,
                onMarkViewed: {},
                onClose: {}
            ),
            ReviewTabBandRow(tone: .muted, status: nil, markViewed: nil, insert: nil, onMarkViewed: {}, onClose: {})
        ]
    }

    static func height(of view: some View, typeSize: DynamicTypeSize) -> CGFloat {
        fittingHeight(of: view
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.dynamicTypeSize, typeSize))
    }

    /// How big `view` lays out when offered `width` (its ideal width
    /// when `nil`) and the foot bar's height, in `language`, with the
    /// "⌘⏎" hint still shown, as it is to someone new to the key.
    static func size(of view: some View, proposing width: CGFloat?, language: String, settings: SettingsStore) -> CGSize {
        NSHostingController(rootView: view
            .environment(settings)
            .environment(PrimaryKeyHint(defaults: nil))
            .environment(\.locale, Locale(identifier: language)))
            .sizeThatFits(in: CGSize(width: width ?? 4000, height: Layout.footBarHeight))
    }

    /// A surface of the window's body: as tall as the body, its foot bar
    /// at its bottom under whatever fills the rest.
    private static func column(width: CGFloat?, @ViewBuilder foot: () -> some View) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(maxHeight: .infinity)
            foot()
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }
}
