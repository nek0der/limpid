// ProjectScrollMemoryTests.swift
// Limpid — a project's scroll positions, kept while no window shows it and brought back once.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

/// A window switching projects in place keeps, for the project it leaves,
/// the turn at the top of the changes panel with the turn selected in it,
/// and the review tab's place in its diff with
/// the tab; it brings them back once as a window shows the project again.
/// A row gone, or a selection moved while the project was away, gives way
/// to the selected row. A removed project's positions go.
@MainActor
struct ProjectScrollMemoryTests {
    typealias Fixture = ProjectWindowsFixture
    typealias Target = ProjectScrollMemory.Target
    typealias Place = ProjectScrollMemory.Place

    private static let rows = ["a", "b", "c", "d", "e"]

    // MARK: - Where a list goes

    /// Where a list goes, given the place it was left at and the row
    /// selected now.
    enum ExpectedTarget: Sendable {
        case remembered(String)
        case selected(String)
    }

    struct TargetCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let remembered: (row: String, selected: String?)?
        let selected: String?
        let expected: ExpectedTarget?
    }

    @Test(arguments: [
        // Past the selected row too: the person left it so.
        TargetCase(testDescription: "left past the selection", remembered: ("e", "b"), selected: "b", expected: .remembered("e")),
        TargetCase(testDescription: "left before the selection", remembered: ("c", "d"), selected: "d", expected: .remembered("c")),
        // ⌘J, a notification, or a write behind the person moved it.
        TargetCase(testDescription: "selection moved down while away", remembered: ("a", "a"), selected: "e", expected: .selected("e")),
        TargetCase(testDescription: "selection moved up while away", remembered: ("e", "e"), selected: "b", expected: .selected("b")),
        TargetCase(testDescription: "remembered row gone", remembered: ("x", "b"), selected: "b", expected: .selected("b")),
        // The scratch row, say, which is not in the sidebar's list.
        TargetCase(testDescription: "selection not in the list", remembered: ("e", "b"), selected: "scratch", expected: .remembered("e")),
        TargetCase(testDescription: "nothing remembered", remembered: nil, selected: "d", expected: .selected("d")),
        TargetCase(testDescription: "nothing remembered or selected", remembered: nil, selected: nil, expected: nil),
        TargetCase(testDescription: "neither in the list", remembered: ("x", nil), selected: "y", expected: nil)
    ])
    func aList_goesToItsRememberedRow_whileTheSelectionStays_elseToTheSelectedRow(_ test: TargetCase) {
        let place = test.remembered.map { Place(row: $0.row, selected: $0.selected) }
        let expected: Target<String>? = switch test.expected {
        case let .remembered(row): .remembered(row)
        case let .selected(row): .selected(row)
        case nil: nil
        }
        #expect(ProjectScrollMemory.target(remembered: place, selected: test.selected, in: Self.rows) == expected)
    }

    @Test func aListLeftAtItsFirstRow_goesBackToItsVeryTop() {
        #expect(ProjectScrollMemory.goesToTop(Target.remembered("a"), in: Self.rows))
        #expect(!ProjectScrollMemory.goesToTop(Target.remembered("c"), in: Self.rows))
        #expect(!ProjectScrollMemory.goesToTop(Target.selected("a"), in: Self.rows), "the selected row is shown, not the top")
        #expect(!ProjectScrollMemory.goesToTop(Target<String>?.none, in: Self.rows))
    }

    @Test func thePanelsSelectedTurn_isTheFirstTheReviewReads_elseWhereItOpens() {
        let turns = ["t1", "t2", "t3", "t4"].map(TurnID.init)
        #expect(ProjectScrollMemory.selectedTurn(rows: turns, shownInReview: [turns[3], turns[1]], opensOn: turns[2]) == turns[1])
        #expect(ProjectScrollMemory.selectedTurn(rows: turns, shownInReview: [], opensOn: turns[2]) == turns[2])
    }

    @Test func thePanelsPlace_isAnotherAgentsNoPlace() {
        let turns = ["t1", "t2", "t3"].map(TurnID.init)
        let claude = ConversationKey(provider: .claude, conversationID: "a", isFallback: false)
        let codex = ConversationKey(provider: .codex, conversationID: "b", isFallback: false)
        let place = ProjectScrollMemory.ChangesPlace(conversation: claude, place: Place(row: turns[0], selected: turns[2]))

        #expect(ProjectScrollMemory.changesTarget(remembered: place, conversation: claude, rows: turns, selected: turns[2]) == Target
            .remembered(turns[0]))
        #expect(ProjectScrollMemory.changesTarget(remembered: place, conversation: codex, rows: turns, selected: turns[2]) == Target
            .selected(turns[2]))
    }

    // MARK: - Kept by project

    /// The panel's place as the window reports it, its list open.
    private static func reportPanel(_ window: ProjectWindowState, turn: String) {
        window.selection.isChangesPanelPresented = true
        window.scrollPlace.changesTurn = TurnID(turn)
        window.scrollPlace.changesSelected = TurnID(turn)
    }

    @Test func eachProject_keepsItsOwnPanelPlace_andGetsItBackOnce() {
        let fixture = Fixture()
        let window = fixture.primary
        Self.reportPanel(window, turn: "a1")

        fixture.choose(fixture.bTab, in: window)
        #expect(fixture.registry.scrollMemories[fixture.a.id]?.changes?.place.row == TurnID("a1"))
        #expect(window.scrollPlace == ProjectScrollReport(), "what the panel reports from now on is b's")
        // b is shown for the first time: nothing comes back, the list goes
        // to its selected turn.
        #expect(window.scrollRestore?.projectID == fixture.b.id)
        #expect(window.scrollRestore?.memory == ProjectScrollMemory())
        Self.reportPanel(window, turn: "b1")

        fixture.choose(fixture.aTab, in: window)
        #expect(window.scrollRestore?.memory.changes?.place.row == TurnID("a1"))
        #expect(window.takeScrollRestore(for: .changes)?.projectID == fixture.a.id)
        #expect(window.takeScrollRestore(for: .changes) == nil, "once")
        #expect(fixture.registry.scrollMemories[fixture.a.id] == nil, "the window holds a's place now")
        #expect(fixture.registry.scrollMemories[fixture.b.id]?.changes?.place.row == TurnID("b1"))
    }

    /// The sidebar lists every project, so its place is the window's: a
    /// switch keeps none of it for the project left, and brings none back.
    @Test func aSwitch_keepsNoSidebarPlaceForTheProject() {
        let fixture = Fixture()
        let window = fixture.primary
        window.sidebarVisibleLines = [.header(fixture.a.id), .row(.project(fixture.a.id))]

        fixture.choose(fixture.bTab, in: window)

        #expect(fixture.registry.scrollMemories[fixture.a.id] == nil)
        #expect(window.pendingScrollLists.isEmpty, "the panel is closed, and no other list takes a part")
        #expect(window.sidebarVisibleLines == [.header(fixture.a.id), .row(.project(fixture.a.id))], "the window's own")
    }

    @Test func aPlaceNotYetShown_isKeptThroughSwitchesThatGoOnBeforeItIs() {
        let fixture = Fixture()
        let window = fixture.primary
        Self.reportPanel(window, turn: "a1")
        fixture.choose(fixture.bTab, in: window)

        // Back to a, and away again before its panel draws or reports.
        fixture.choose(fixture.aTab, in: window)
        fixture.choose(fixture.cTab, in: window)
        #expect(fixture.registry.scrollMemories[fixture.a.id]?.changes?.place.row == TurnID("a1"))

        fixture.choose(fixture.aTab, in: window)
        #expect(window.takeScrollRestore(for: .changes)?.memory.changes?.place.row == TurnID("a1"))
    }

    @Test func thePanelsPlace_isKeptWhileThePanelIsOpen_withItsAgentAndSelection() {
        let fixture = Fixture()
        let window = fixture.primary
        let conversation = ConversationKey(provider: .claude, conversationID: "a", isFallback: false)
        window.scrollPlace.changesConversation = conversation
        window.scrollPlace.changesTurn = TurnID("t7")
        window.scrollPlace.changesSelected = TurnID("t9")
        window.selection.isChangesPanelPresented = true

        fixture.choose(fixture.bTab, in: window)
        let place = ProjectScrollMemory.ChangesPlace(conversation: conversation, place: Place(row: TurnID("t7"), selected: TurnID("t9")))
        #expect(fixture.registry.scrollMemories[fixture.a.id]?.changes == place)
        // The panel is the window's, so it stays open for b, shown for the
        // first time: its list takes its part, which brings nothing back.
        #expect(window.selection.isChangesPanelPresented)
        #expect(window.takeScrollRestore(for: .changes)?.memory.changes == nil)

        fixture.choose(fixture.aTab, in: window)
        #expect(window.takeScrollRestore(for: .changes)?.memory.changes == place, "a's panel opens again with a's view")
        #expect(fixture.registry.scrollMemories[fixture.b.id] == nil)
    }

    @Test func aClosedPanel_takesNoPartOfTheRestore() {
        let fixture = Fixture()
        let window = fixture.primary
        Self.reportPanel(window, turn: "a1")
        fixture.choose(fixture.bTab, in: window)
        // The panel is the window's: closed here, it stays closed as the
        // window goes back to a.
        window.selection.isChangesPanelPresented = false
        fixture.choose(fixture.aTab, in: window)

        // Opened later, its list is one opened, not one coming back.
        #expect(window.scrollRestore?.projectID == fixture.a.id)
        #expect(window.takeScrollRestore(for: .changes) == nil)
    }

    @Test func aClosedWindowsProject_keepsItsPositions() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        Self.reportPanel(other, turn: "c1")

        fixture.registry.close(other.id, in: fixture.session)
        #expect(fixture.registry.scrollMemories[fixture.c.id]?.changes?.place.row == TurnID("c1"))

        fixture.primary.selection.isChangesPanelPresented = true
        fixture.choose(fixture.cTab, in: fixture.primary)
        #expect(fixture.primary.scrollRestore?.memory.changes?.place.row == TurnID("c1"))
    }

    @Test func removingAProject_forgetsItsPositions() {
        let fixture = Fixture()
        let window = fixture.primary
        fixture.choose(fixture.cTab, in: window)
        Self.reportPanel(window, turn: "c1")
        fixture.choose(fixture.aTab, in: window)
        #expect(fixture.registry.scrollMemories[fixture.c.id] != nil)

        fixture.session.removeProject(fixture.c.id)
        // As the app does when the projects change.
        fixture.registry.forgetProjectsGone(in: fixture.session)

        #expect(fixture.registry.scrollMemories[fixture.c.id] == nil)
    }

    // MARK: - The review tab

    @Test func aParkedReviewTab_bringsBackItsPlaceInTheDiff_forItsOwnOpening() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let place = ReviewScrollAnchor(key: "h|a.swift", offset: -12)
        let tab = try ProjectWindowsFixture.review()
        window.review = tab
        window.readReviewScroll = { place }

        fixture.choose(fixture.bTab, in: window)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.scroll == place)
        #expect(window.readReviewScroll == nil, "no diff draws a tab here now")
        fixture.choose(fixture.aTab, in: window)

        #expect(window.review?.opening == tab.opening)
        #expect(window.reviewScrollRestore == ReviewTabScroll(opening: tab.opening, anchor: place))
    }

    @Test func aPlaceNotPutBackYet_goesWithTheTabAgain() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let place = ReviewScrollAnchor(key: "h|a.swift", offset: -12)
        let tab = try ProjectWindowsFixture.review()
        window.review = tab
        window.readReviewScroll = { place }
        fixture.choose(fixture.bTab, in: window)
        fixture.choose(fixture.aTab, in: window)

        // Away again before the diff is drawn for the tab, or has read the
        // place's file: the diff it had is gone, and none reads anew yet.
        fixture.choose(fixture.bTab, in: window)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.scroll == place)
    }

    @Test func aPlaceKeptForAnotherOpening_goesWithNoTab() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let earlier = try ProjectWindowsFixture.review()
        window.reviewScrollRestore = ReviewTabScroll(opening: earlier.opening, anchor: ReviewScrollAnchor(key: "h|a.swift", offset: 0))
        // Another review opened in its place.
        window.review = try ProjectWindowsFixture.review()

        fixture.choose(fixture.bTab, in: window)

        let parked = try #require(fixture.registry.parkedReviews[fixture.a.id]?.tab)
        #expect(parked.scroll == nil)
    }
}
